import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import SoleCloud

private final class CloudStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, headers, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class CloudSessionTests: XCTestCase {
    private let cloudClient = "11111111-1111-1111-1111-111111111111"
    private let streamClient = "22222222-2222-2222-2222-222222222222"
    override func tearDown() { CloudStub.handler = nil; super.tearDown() }
    private func service() -> CloudSessionService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudStub.self]
        return CloudSessionService(session: URLSession(configuration: configuration))
    }
    private var sessionJSON: Data {
        Data("{\"sessionId\":\"session-1\",\"gkClientId\":\"\(cloudClient)\",\"streamServerClientId\":\"\(streamClient)\"}".utf8)
    }
    func testUsesCronosClientsAndCorrectSpecificationInsteadOfLegacyStartClients() async throws {
        let ids = sessionJSON
        CloudStub.handler = { request in
            switch request.url!.path {
            case "/v1/client_ids":
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "cronos")
                return (200, [:], ids)
            case "/v1/config":
                return (200, [:], Data("{\"configKey\":\"config-key\"}".utf8))
            case "/v1/sessions/start":
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Gaikai-Session"), "config-key")
                return (200, ["X-Gaikai-Session": "rotated-key"], Data("{\"sessionId\":\"session-1\",\"gkClientId\":\"legacy\",\"streamServerClientId\":\"legacy\"}".utf8))
            case "/v1/sessions/session-1/authorize":
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Gaikai-Session"), "rotated-key")
                let data: Data
                if let body = request.httpBody { data = body }
                else {
                    let stream = try XCTUnwrap(request.httpBodyStream)
                    stream.open(); defer { stream.close() }
                    var bytes = [UInt8](repeating: 0, count: 16384)
                    let size = stream.read(&bytes, maxLength: bytes.count)
                    data = Data(bytes.prefix(size))
                }
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let spec = try XCTUnwrap(body["requestGameSpecification"] as? [String: Any])
                XCTAssertEqual(spec["gkCloudAuthCode"] as? String, "cloud-code")
                XCTAssertEqual(spec["streamServerAuthCode"] as? String, "stream-code")
                XCTAssertEqual(spec["entitlementId"] as? String, "UP0001-PPSA00001_00-GAME000000000000")
                XCTAssertEqual(spec["protocolVersion"] as? Int, 12)
                XCTAssertEqual(spec["isPlusMember"] as? Bool, false)
                XCTAssertEqual(spec["parentalLevel"] as? Int, 0)
                XCTAssertNil(body["gkCloudAuthCode"])
                return (200, [:], Data("{}".utf8))
            default: return (404, [:], Data())
            }
        }
        let client = service()
        let session = try await client.begin(entitlementID: "UP0001-PPSA00001_00-GAME000000000000", isPlusMember: false)
        XCTAssertEqual(session.gkClientId, cloudClient)
        try await client.authorize(session, cloudCode: "cloud-code", streamCode: "stream-code")
    }
    func testEveryHeightOfTheSettingsCanBeAskedForAndIsSixteenByNine() {
        XCTAssertEqual(CloudSessionService.widths.keys.sorted(), [360, 540, 720, 1080, 1440, 2160])
        for (height, width) in CloudSessionService.widths { XCTAssertEqual(width * 9, height * 16, "\(width)x\(height)") }
    }

    func testFailedAuthorizationNeverAllowsDatacenterRequest() async throws {
        let ids = sessionJSON
        CloudStub.handler = { request in
            switch request.url!.path {
            case "/v1/client_ids", "/v1/sessions/start": return (200, [:], ids)
            case "/v1/config": return (200, [:], Data("{\"configKey\":\"issued-key\"}".utf8))
            case "/v1/sessions/session-1/authorize": return (400, [:], Data("{\"componentCode\":\"002\",\"errors\":[{\"eventCode\":2001,\"description\":\"must never be exposed\"}]}".utf8))
            default: XCTFail("Unauthorized endpoint"); return (404, [:], Data())
            }
        }
        let client = service(), session = try await client.begin()
        do { try await client.authorize(session, cloudCode: "code", streamCode: "code"); XCTFail("Failed grant") }
        catch CloudProtocol.Failure.serviceCode(let status, _, let code, _) { XCTAssertEqual(status, 400); XCTAssertEqual(code, "002.2001") }
        do { _ = try await client.datacenterResponse(); XCTFail("Unauthorized") } catch CloudProtocol.Failure.unauthorized {}
    }
    func testCallbackRejectsForgeryAndDuplicateParameters() throws {
        XCTAssertEqual(try CloudProtocol.code(from: URL(string: "gaikai://local/?state=nonce&code=a%2Bb")!, expectedState: "nonce"), "a+b")
        for url in ["gaikai://other?state=nonce&code=x", "gaikai://local?state=wrong&code=x", "gaikai://local?state=nonce&code=x&code=y", "gaikai://local?state=nonce&state=nonce&code=x", "gaikai://local?state=nonce&code=x&error=denied", "gaikai://local:80?state=nonce&code=x", "gaikai://local?state=nonce&code=%20", "gaikai://local?state=nonce&code=x#fragment"] {
            XCTAssertThrowsError(try CloudProtocol.code(from: URL(string: url)!, expectedState: "nonce"))
        }
    }
    func testProviderErrorsDoNotExposeArbitraryResponseText() throws {
        XCTAssertEqual(CloudProtocol.safeProviderError("invalid_scope"), "invalid_scope")
        XCTAssertNil(CloudProtocol.safeProviderError("secret-account-detail"))
        do {
            _ = try CloudProtocol.code(from: URL(string: "gaikai://local?state=nonce&error=invalid_scope")!, expectedState: "nonce")
            XCTFail("Rejected grant must fail")
        } catch CloudProtocol.Failure.provider(let code) { XCTAssertEqual(code, "invalid_scope") }
        do {
            _ = try CloudProtocol.code(from: URL(string: "gaikai://local?state=wrong&error=invalid_scope")!, expectedState: "nonce")
            XCTFail("Wrong state must fail before provider error")
        } catch CloudProtocol.Failure.invalidCallback {}
    }
    func testAuthorizationURLBindsGrantToStateAndDevice() throws {
        let url = try CloudProtocol.authorizationURL(clientID: cloudClient, streamServer: true, state: "a+b&other=x", deviceID: String(repeating: "a", count: 48))
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.host, "ca.account.sony.com")
        XCTAssertEqual(parts.path, "/api/authz/v3/oauth/authorize")
        let items = parts.queryItems!
        XCTAssertEqual(items.first(where: { $0.name == "state" })?.value, "a+b&other=x")
        XCTAssertEqual(items.first(where: { $0.name == "redirect_uri" })?.value, "gaikai://local")
        XCTAssertThrowsError(try CloudProtocol.authorizationURL(clientID: "bad", streamServer: false, state: "a", deviceID: "bad"))
    }
    func testSessionRejectsPathInjection() throws {
        let data = Data("{\"sessionId\":\"../../other\",\"gkClientId\":\"\(cloudClient)\",\"streamServerClientId\":\"\(streamClient)\"}".utf8)
        let decoded = try JSONDecoder().decode(CloudProtocol.Session.self, from: data)
        XCTAssertThrowsError(try decoded.validate())
    }
    func testSessionRequiresServerCredentialBeforeDatacenterRequestAndResetClearsIt() async throws {
        let sessionJSON = sessionJSON
        var datacenterRequests = 0
        CloudStub.handler = { request in
            switch request.url!.path {
            case "/v1/client_ids": return (200, [:], sessionJSON)
            case "/v1/config": return (200, [:], Data("{\"configKey\":\"configuration-key\"}".utf8))
            case "/v1/sessions/start": return (200, [:], sessionJSON)
            case "/v1/sessions/session-1/authorize":
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Gaikai-SessionId"), "session-1")
                return (200, ["X-Gaikai-Session": "issued-key"], Data("{}".utf8))
            case "/v1/sessions/session-1/datacenters":
                datacenterRequests += 1
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Gaikai-Session"), "issued-key")
                return (200, [:], Data("[]".utf8))
            default: XCTFail("Unexpected endpoint"); return (404, [:], Data())
            }
        }
        let client = service()
        let session = try await client.begin()
        do { _ = try await client.datacenterResponse(); XCTFail("Unauthenticated request") } catch CloudProtocol.Failure.unauthorized {}
        XCTAssertEqual(datacenterRequests, 0)
        try await client.authorize(session, cloudCode: "cloud-code", streamCode: "stream-code")
        _ = try await client.datacenterResponse()
        XCTAssertEqual(datacenterRequests, 1)
        await client.reset()
        do { _ = try await client.datacenterResponse(); XCTFail("Reset must revoke session") } catch CloudProtocol.Failure.unauthorized {}
        XCTAssertEqual(datacenterRequests, 1)
    }
    func testTheLockEndsAnotherSessionOfTheAccountOnlyWhenAsked() async throws {
        let sessionJSON = sessionJSON
        var locks: [String] = []
        var acquired = false
        CloudStub.handler = { request in
            switch request.url!.path {
            case "/v1/client_ids", "/v1/sessions/start": return (200, [:], sessionJSON)
            case "/v1/config": return (200, [:], Data("{\"configKey\":\"configuration-key\"}".utf8))
            case "/v1/sessions/session-1/authorize": return (200, ["X-Gaikai-Session": "issued-key"], Data("{}".utf8))
            case "/v1/sessions/session-1/lock":
                XCTAssertEqual(request.httpMethod, "POST")
                locks.append(request.url!.query ?? "")
                return (200, [:], Data("{\"lockAcquired\":\(acquired)}".utf8))
            default: XCTFail("Unexpected endpoint"); return (404, [:], Data())
            }
        }
        let client = service()
        let session = try await client.begin()
        try await client.authorize(session, cloudCode: "cloud-code", streamCode: "stream-code")
        do { try await client.lock(); XCTFail("Another session holds the account") } catch CloudProtocol.Failure.sessionBusy {}
        XCTAssertEqual(locks, ["forceLogout=false"], "Without the player's choice the other session is left alone")
        acquired = true
        try await client.lock(forceLogout: true)
        XCTAssertEqual(locks, ["forceLogout=false", "forceLogout=true"])
        _ = try await client.networkProbeCredential()
        let plain = CloudProtocol.Session(sessionId: "s", gkClientId: cloudClient, streamServerClientId: streamClient)
        XCTAssertEqual(CloudSessionService.lockURL(plain, forceLogout: false).absoluteString, "https://cc.prod.gaikai.com/v1/sessions/s/lock?forceLogout=false")
        XCTAssertEqual(CloudSessionService.lockURL(plain, forceLogout: true).absoluteString, "https://cc.prod.gaikai.com/v1/sessions/s/lock?forceLogout=true")
    }
    private final class LockAnswers: @unchecked Sendable {
        var answers: [(Int, String)]
        var locks: [String] = []
        init(_ answers: [(Int, String)]) { self.answers = answers }
    }
    private func lockedService(_ answers: LockAnswers) async throws -> CloudSessionService {
        let sessionJSON = sessionJSON
        CloudStub.handler = { request in
            switch request.url!.path {
            case "/v1/client_ids", "/v1/sessions/start": return (200, [:], sessionJSON)
            case "/v1/config": return (200, [:], Data("{\"configKey\":\"configuration-key\"}".utf8))
            case "/v1/sessions/session-1/authorize": return (200, ["X-Gaikai-Session": "issued-key"], Data("{}".utf8))
            case "/v1/sessions/session-1/lock":
                answers.locks.append(request.url!.query ?? "")
                let (status, body) = answers.answers.count > 1 ? answers.answers.removeFirst() : answers.answers[0]
                return (status, ["X-Gaikai-Session": "rotated-secret-key", "Retry-After": "3"], Data(body.utf8))
            default: XCTFail("Unexpected endpoint"); return (404, [:], Data())
            }
        }
        let client = service()
        let session = try await client.begin()
        try await client.authorize(session, cloudCode: "cloud-code", streamCode: "stream-code")
        return client
    }
    func testAForcedLockIsTriedAgainWhileSonyEndsTheOtherSession() async throws {
        let answers = LockAnswers([(200, #"{"lockAcquired":false,"state":"PENDING","sessionId":"session-1"}"#), (200, #"{"lockAcquired":false}"#), (200, #"{"lockAcquired":true}"#)])
        let client = try await lockedService(answers)
        var waits: [Int] = []
        try await CloudSessionService.acquireLock(client, forceLogout: true, interval: .milliseconds(20), limit: .seconds(10)) { waits.append($0) }
        XCTAssertEqual(answers.locks, Array(repeating: "forceLogout=true", count: 3), "Each try keeps the player's choice")
        XCTAssertEqual(waits.count, 2, "The wait is reported before every retry")
        _ = try await client.networkProbeCredential()
        let trace = await client.lockTrace
        XCTAssertEqual(trace.map { $0["attempt"] as? Int }, [1, 2, 3])
        XCTAssertEqual(trace.map { $0["forced"] as? Bool }, [true, true, true])
        XCTAssertEqual(trace.map { $0["status"] as? Int }, [200, 200, 200])
        XCTAssertEqual(trace.map { $0["retryAfter"] as? Int }, [3, 3, 3])
        let fields = trace.map { ($0["answer"] as? [String: Any])?["fields"] as? [String: [String: Any]] }
        XCTAssertEqual(fields.map { $0?["lockAcquired"]?["value"] as? Bool }, [false, false, true])
        XCTAssertEqual(fields[0]?["state"]?["value"] as? String, "PENDING")
        XCTAssertEqual(fields[0]?["sessionId"]?["type"] as? String, "string(9)")
        XCTAssertNil(fields[0]?["sessionId"]?["value"], "Only the type of an identifier is recorded")
        let elapsed = trace.compactMap { $0["elapsedMs"] as? Int }
        XCTAssertEqual(elapsed, elapsed.sorted(), "Elapsed time is measured from the first try")
        let text = String(decoding: try JSONSerialization.data(withJSONObject: trace), as: UTF8.self)
        for secret in ["session-1", "issued-key", "rotated-secret-key", "configuration-key", "cloud-code", "stream-code"] { XCTAssertFalse(text.contains(secret), secret) }
    }
    func testAForcedLockNeverAcquiredEndsBusyAfterItsBound() async throws {
        let answers = LockAnswers([(200, #"{"lockAcquired":false}"#)])
        let client = try await lockedService(answers)
        var waits = 0
        let started = ContinuousClock.now
        do { try await CloudSessionService.acquireLock(client, forceLogout: true, interval: .milliseconds(20), limit: .milliseconds(150)) { _ in waits += 1 }; XCTFail("The other session never ended") }
        catch CloudProtocol.Failure.sessionBusy {}
        XCTAssertLessThan(started.duration(to: .now), .seconds(3))
        XCTAssertGreaterThanOrEqual(answers.locks.count, 2); XCTAssertLessThanOrEqual(answers.locks.count, 9)
        XCTAssertEqual(Set(answers.locks), ["forceLogout=true"])
        XCTAssertEqual(waits, answers.locks.count - 1)
        let waiting = Task { try await CloudSessionService.acquireLock(client, forceLogout: true, interval: .seconds(30), limit: .seconds(60)) }
        try await Task.sleep(nanoseconds: 100_000_000)
        waiting.cancel()
        do { try await waiting.value; XCTFail("A cancelled start does not continue") } catch is CancellationError {}
    }
    func testAnOrdinaryLockIsNeverRepeatedNorForced() async throws {
        let answers = LockAnswers([(200, #"{"lockAcquired":false}"#)])
        let client = try await lockedService(answers)
        var waits = 0
        do { try await CloudSessionService.acquireLock(client, forceLogout: false, interval: .milliseconds(1), limit: .seconds(10)) { _ in waits += 1 }; XCTFail("Busy") }
        catch CloudProtocol.Failure.sessionBusy {}
        XCTAssertEqual(answers.locks, ["forceLogout=false"]); XCTAssertEqual(waits, 0)
        let trace = await client.lockTrace
        XCTAssertEqual(trace.count, 1); XCTAssertEqual(trace.first?["forced"] as? Bool, false)
        answers.answers = [(409, #"{"errors":[{"name":"sessionAlreadyLocked","eventCode":"002.2005","message":"user secret-name"}]}"#)]
        do { try await CloudSessionService.acquireLock(client, forceLogout: false); XCTFail("Refused") } catch CloudProtocol.Failure.service(409, _) {}
        let refused = await client.lockTrace.last
        XCTAssertEqual(refused?["status"] as? Int, 409)
        let error = (((refused?["answer"] as? [String: Any])?["fields"] as? [String: Any])?["errors"] as? [String: Any])?["first"] as? [String: [String: Any]]
        XCTAssertEqual(error?["name"]?["value"] as? String, "sessionAlreadyLocked")
        XCTAssertEqual(error?["eventCode"]?["value"] as? String, "002.2005")
        XCTAssertNil(error?["message"]?["value"])
    }
    func testAuthorizationRetainsServerIssuedKeyWhenNotRotated() async throws {
        let sessionJSON = sessionJSON
        CloudStub.handler = { request in
            if request.url!.path == "/v1/client_ids" { return (200, [:], sessionJSON) }
            if request.url!.path == "/v1/config" { return (200, [:], Data("{\"configKey\":\"configuration-key\"}".utf8)) }
            if request.url!.path == "/v1/sessions/start" { return (200, [:], sessionJSON) }
            return (200, [:], Data("{}".utf8))
        }
        let client = service(), session = try await client.begin()
        do { _ = try await client.datacenterResponse(); XCTFail("Key alone is not authorization") } catch CloudProtocol.Failure.unauthorized {}
        try await client.authorize(session, cloudCode: "code", streamCode: "code")
        _ = try await client.datacenterResponse()
    }
}
