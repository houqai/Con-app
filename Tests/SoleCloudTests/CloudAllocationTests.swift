import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import SoleCloud

private final class AllocationStub: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest, [String: Any]?) throws -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, headers, data) = try Self.handler!(request, Self.body(request))
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func body(_ request: URLRequest) -> [String: Any]? {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

final class CloudAllocationTests: XCTestCase {
    private let key = Data(repeating: 7, count: 16).base64EncodedString()
    override func tearDown() { AllocationStub.handler = nil; super.tearDown() }

    private func slotJSON(_ overrides: [String: Any] = [:]) -> Data {
        var slot: [String: Any] = ["publicIp": "192.0.2.5", "port": 2053, "privateIp": "10.0.0.123", "handshakeKey": key,
                                   "launchSpecification": "{\"a\":1}", "sessionId": "cloud-session-abc123"]
        slot.merge(overrides) { $1 }
        return try! JSONSerialization.data(withJSONObject: ["launchSlot": slot])
    }

    func testDecodesLaunchSlotAndRedactsKey() throws {
        guard case .ready(let slot) = try CloudAllocation.decode(slotJSON()) else { return XCTFail("Expected slot") }
        XCTAssertEqual(slot.publicIp, "192.0.2.5"); XCTAssertEqual(slot.port, 2053)
        XCTAssertEqual(slot.handshakeKey.count, 16); XCTAssertEqual(slot.psnWrapperType, 0x7B)
        XCTAssertEqual(slot.sessionId, "cloud-session-abc123")
        XCTAssertFalse(slot.description.contains(key)); XCTAssertFalse(String(describing: slot).contains(key))
    }
    func testLaunchSpecificationObjectAndStringPort() throws {
        guard case .ready(let slot) = try CloudAllocation.decode(slotJSON(["launchSpecification": ["x": 1], "port": "2053"])) else { return XCTFail() }
        XCTAssertEqual(slot.port, 2053); XCTAssertEqual(slot.launchSpecification, "{\"x\":1}")
    }
    func testRejectsInvalidSlots() {
        for bad: [String: Any] in [["handshakeKey": "AAAA"], ["handshakeKey": "not base64"], ["publicIp": "300.1.1.1"], ["port": 0], ["port": true], ["port": 2053.5], ["port": 1e30],
                                   ["sessionId": ""], ["sessionId": "a b"], ["sessionId": String(repeating: "a", count: 129)], ["privateIp": "bad"]] {
            XCTAssertThrowsError(try CloudAllocation.decode(slotJSON(bad)), "\(bad)")
        }
        XCTAssertThrowsError(try CloudAllocation.decode(Data("{}".utf8)))
        XCTAssertThrowsError(try CloudAllocation.decode(Data("[]".utf8)))
    }
    func testDecodesQueue() throws {
        let data = Data("{\"queued\":true,\"pollFrequency\":15,\"waitTimeEstimate\":120,\"queuePosition\":5}".utf8)
        guard case .queued(let position, let estimate, let poll) = try CloudAllocation.decode(data) else { return XCTFail() }
        XCTAssertEqual(position, 5); XCTAssertEqual(estimate, 120); XCTAssertEqual(poll, 15)
        let shown = Data("{\"queued\":true,\"queuePosition\":40,\"displayQueuePosition\":7}".utf8)
        guard case .queued(let place, _, let frequency) = try CloudAllocation.decode(shown) else { return XCTFail() }
        XCTAssertEqual(place, 7); XCTAssertEqual(frequency, 15)
    }
    func testDecodesSlotFieldsBesideLaunchSlot() throws {
        let object: [String: Any] = ["launchSlot": ["publicIp": "192.0.2.5", "port": 2053, "privateIp": "10.0.0.9"],
                                     "handshakeKey": key, "sessionId": "cloud-session-abc123", "launchSpecification": "{\"a\":1}"]
        guard case .ready(let slot) = try CloudAllocation.decode(JSONSerialization.data(withJSONObject: object)) else { return XCTFail("Expected slot") }
        XCTAssertEqual(slot.publicIp, "192.0.2.5"); XCTAssertEqual(slot.handshakeKey.count, 16)
        XCTAssertEqual(slot.sessionId, "cloud-session-abc123"); XCTAssertEqual(slot.launchSpecification, "{\"a\":1}")
        XCTAssertEqual(slot.psnWrapperType, 9)
    }
    func testDecodesDataMigrationAsWaiting() throws {
        let data = Data("{\"dataMigration\":true,\"dataMigrationPercentageComplete\":40,\"pollFrequency\":10,\"launchSlot\":{}}".utf8)
        guard case .migrating(let percent, let poll) = try CloudAllocation.decode(data) else { return XCTFail() }
        XCTAssertEqual(percent, 40); XCTAssertEqual(poll, 10)
    }
    func testQueuePolicy() {
        XCTAssertEqual(CloudQueuePolicy.deadline(estimate: 120), 240)
        XCTAssertEqual(CloudQueuePolicy.deadline(estimate: 2000), 900)
        XCTAssertEqual(CloudQueuePolicy.deadline(estimate: nil), 900)
        XCTAssertEqual(CloudQueuePolicy.pollInterval(0), 5); XCTAssertEqual(CloudQueuePolicy.pollInterval(600), 60)
    }
    func testSelectAndAllocateFlow() async throws {
        let ids = Data("{\"sessionId\":\"session-1\",\"gkClientId\":\"11111111-1111-1111-1111-111111111111\",\"streamServerClientId\":\"22222222-2222-2222-2222-222222222222\"}".utf8)
        let slot = slotJSON()
        var calls: [String] = []
        AllocationStub.handler = { request, body in
            let path = request.url!.path
            calls.append(request.httpMethod! + " " + path)
            switch path {
            case "/v1/client_ids", "/v1/sessions/start": return (200, [:], ids)
            case "/v1/config": return (200, [:], Data("{\"configKey\":\"configuration-key\"}".utf8))
            case "/v1/sessions/session-1/authorize": return (200, ["X-Gaikai-Session": "issued-key"], Data("{}".utf8))
            case "/v1/sessions/session-1/datacenters/select":
                XCTAssertNil(body?["dataCenter"])
                XCTAssertNotNil(body?["requestGameSpecification"] as? [String: Any])
                let pings = body?["pingResults"] as? [[String: Any]]
                XCTAssertEqual(pings?.map { $0["dataCenter"] as? String }, ["EU-2", "EU-1", "EU-3"])
                let ping = pings?.first
                XCTAssertEqual(ping?["publicIp"] as? String, "192.0.2.2")
                XCTAssertEqual(ping?["port"] as? Int, 2054)
                XCTAssertEqual(ping?["mtu_in"] as? Int, 1400)
                XCTAssertEqual(ping?["mtu_out"] as? Int, 1254)
                XCTAssertEqual(ping?["rtt"] as? Int, 31)
                XCTAssertEqual(ping?["rtts"] as? [Int], [31])
                XCTAssertEqual(ping?["maxBandwidth"] as? Int, 50000)
                XCTAssertEqual(ping?["measured"] as? Bool, true)
                XCTAssertEqual(pings?.last?["measured"] as? Bool, false)
                XCTAssertEqual(pings?.last?["rtt"] as? Int, 999)
                XCTAssertEqual(pings?.last?["mtu_in"] as? Int, 0)
                return (200, ["X-Gaikai-Session": "rotated-key"], Data("{\"network\":{\"port\":2053}}".utf8))
            case "/v1/sessions/session-1/allocate":
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Gaikai-Session"), "rotated-key")
                XCTAssertEqual(body?["dataCenter"] as? String, "EU-2")
                let network = body?["network"] as? [String: Any]
                XCTAssertEqual(network?["port"] as? Int, 2053); XCTAssertEqual(network?["rtt"] as? Int, 31)
                XCTAssertEqual(body?["stateExecutionTime"] as? Double, 1200)
                XCTAssertEqual(body?["streamTestTime"] as? Double, 350)
                return (200, [:], slot)
            default: XCTFail("Unexpected \(path)"); return (404, [:], Data())
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AllocationStub.self]
        let client = CloudSessionService(session: URLSession(configuration: configuration))
        let session = try await client.begin(entitlementID: "EP0000-PPSA00000_00-GAME")
        do { _ = try await client.allocate(network: .init(port: 50000)); XCTFail() } catch CloudProtocol.Failure.unauthorized {}
        do { _ = try await client.selectDatacenter("EU-2", results: []); XCTFail() } catch CloudProtocol.Failure.unauthorized {}
        try await client.authorize(session, cloudCode: "c", streamCode: "s")
        do { _ = try await client.selectDatacenter("../x", results: []); XCTFail() } catch CloudDatacenter.Failure.invalidName {}
        let centers = try CloudDatacenter.decode(Data("[{\"dataCenter\":\"EU-1\",\"publicIp\":\"192.0.2.1\",\"port\":2053},{\"dataCenter\":\"EU-2\",\"publicIp\":\"192.0.2.2\",\"port\":2054,\"maxBandwidth\":50000},{\"dataCenter\":\"EU-3\",\"publicIp\":\"192.0.2.3\",\"port\":2053}]".utf8))
        let results = [CloudPingResult(center: centers[0], rttMs: 48), CloudPingResult(center: centers[1], rttMs: 31, mtuIn: 1400), CloudPingResult(center: centers[2], rttMs: nil)]
        do { _ = try await client.selectDatacenter("EU-2", results: results); XCTFail() } catch CloudProtocol.Failure.invalidResponse {}
        do { _ = try await client.selectDatacenter("EU-3", results: CloudPingResult.ordered(results, selected: "EU-3", exclusive: true, distant: true)); XCTFail() } catch CloudDatacenter.Failure.unreachable {}
        XCTAssertFalse(calls.contains("POST /v1/sessions/session-1/datacenters/select"))
        XCTAssertEqual(CloudPingResult.ordered(results, selected: "EU-1", exclusive: true, distant: true).map(\.center.id), ["EU-1"])
        XCTAssertTrue(CloudPingResult.ordered(results, selected: "missing", exclusive: false, distant: true).isEmpty)
        let port = try await client.selectDatacenter("EU-2", results: CloudPingResult.ordered(results, selected: "EU-2", exclusive: false, distant: true))
        XCTAssertEqual(port, 2053)
        var network = CloudNetworkEstimate(port: port!, rttMs: 31)
        network.stateExecutionTimeMs = 1200; network.streamTestTimeMs = 350
        guard case .ready(let result) = try await client.allocate(network: network) else { return XCTFail() }
        XCTAssertEqual(result.port, 2053)
        XCTAssertEqual(Array(calls.suffix(2)), ["POST /v1/sessions/session-1/datacenters/select", "POST /v1/sessions/session-1/allocate"])
        await client.reset()
        do { _ = try await client.allocate(network: .init(port: 50000)); XCTFail("Reset clears selection") } catch CloudProtocol.Failure.unauthorized {}
    }
}
