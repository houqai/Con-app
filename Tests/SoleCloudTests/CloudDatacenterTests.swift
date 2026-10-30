import XCTest
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Network)
import Network
#endif
@testable import SoleCloud

final class CloudDatacenterTests: XCTestCase {
    func testTheModulesOwnSHA256IsRight() {
        func hex(_ data: Data) -> String { SHA256Digest.hash(data).map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(hex(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)), "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(hex(Data(repeating: 0x61, count: 1_000_000)), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
        #if canImport(CryptoKit)
        var generator = SystemRandomNumberGenerator()
        for length in Array(0...130) + [255, 256, 1000, 4096] {
            let data = Data((0..<length).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
            XCTAssertEqual(SHA256Digest.hash(data), Data(SHA256.hash(data: data)), "\(length) bytes")
        }
        #endif
    }
    func testAnIPv6AddressIsReadAsTheSystemReadsIt() {
        let valid = ["::", "::1", "1::", "2001:db8::1", "2001:0db8:85a3:0000:0000:8a2e:0370:7334", "fe80::1ff:fe23:4567:890a", "::ffff:192.0.2.1", "64:ff9b::192.0.2.33",
                     "1:2:3:4:5:6:7:8", "1:2:3:4:5:6:7::", "::2:3:4:5:6:7:8", "1:2:3:4:5:6:192.0.2.1", "ABCD:ef01::"]
        let invalid = ["", "1:2:3:4:5:6:7", "1:2:3:4:5:6:7:8:9", "1:2:3:4:5:6:7:8::", "1::2::3", "12345::1", "g::1", ":1:2:3:4:5:6:7", "1:2:3:4:5:6:7:", ":::", "1.2.3.4",
                       "::ffff:300.0.2.1", "1:2:3:4:5:6:7:192.0.2.1", "192.0.2.1::1", "2001:db8::1 ", "example.com"]
        for address in valid { XCTAssertTrue(CloudDatacenter.validIPv6(address), "'\(address)'") }
        for address in invalid { XCTAssertFalse(CloudDatacenter.validIPv6(address), "'\(address)'") }
        #if canImport(Network)
        for address in valid + invalid {
            XCTAssertEqual(CloudDatacenter.validIPv6(address), IPv6Address(address) != nil, "'\(address)'")
        }
        #endif
        XCTAssertFalse(CloudDatacenter.validIPv6("fe80::1%en0"), "A scoped (zone) address is local to this machine")
        XCTAssertTrue(CloudDatacenter.validAddress("2001:db8::1"))
    }
    func testAcceptsServerListWithoutInventingLatency() throws {
        let centers = try CloudDatacenter.decode(Data("[{\"dataCenter\":\"EU-1\",\"publicIp\":\"192.0.2.10\",\"port\":2053,\"maxBandwidth\":50000}]".utf8))
        XCTAssertEqual(centers.map(\.id), ["EU-1"])
        XCTAssertEqual(centers.first?.port, 2053)
    }
    func testReadableNamesAddSiteLetterOnlyForSeveralSitesInOneCity() {
        let ids = ["tyob", "stoa", "fraa", "frab", "mila"]
        XCTAssertEqual(ids.map { CloudDatacenterName.display($0, among: ids) }, ["Tokyo, Japan", "Stockholm, Sweden", "Frankfurt, Germany · A", "Frankfurt, Germany · B", "Milan, Italy"])
        XCTAssertEqual(CloudDatacenterName.display("FRAB"), "Frankfurt, Germany")
        for id in ["qqqa", "EU-1", "frankfurt", "fr", ""] { XCTAssertEqual(CloudDatacenterName.display(id, among: ids), id) }
    }
    func testLatencyAboveSonyLimitIsSubstitutedOnlyWhenDistantServersAreAllowed() throws {
        XCTAssertEqual([31, 80, 81, 107, 600].map { CloudPingPolicy.reported($0, distant: true) }, [31, 80, 75, 75, 75])
        XCTAssertEqual([31, 80, 81, 107, 600].map { CloudPingPolicy.reported($0, distant: false) }, [31, 80, 81, 107, 600])
        let centers = try CloudDatacenter.decode(Data("[{\"dataCenter\":\"tyob\",\"publicIp\":\"192.0.2.1\",\"port\":2053},{\"dataCenter\":\"mila\",\"publicIp\":\"192.0.2.2\",\"port\":2053},{\"dataCenter\":\"stoa\",\"publicIp\":\"192.0.2.3\",\"port\":2053}]".utf8))
        let results = [CloudPingResult(center: centers[0], rttMs: 107), CloudPingResult(center: centers[1], rttMs: 183), CloudPingResult(center: centers[2], rttMs: nil)]
        let rows = CloudPingResult.ordered(results, selected: "tyob", exclusive: false, distant: true)
        XCTAssertEqual(rows.map(\.center.id), ["tyob", "mila", "stoa"])
        XCTAssertEqual(rows.map(\.rttMs), [75, 183, nil])
        XCTAssertEqual(rows[0].json["rtts"] as? [Int], [75])
        XCTAssertEqual(rows[0].json["measured"] as? Bool, true)
        XCTAssertEqual(CloudPingResult.ordered(results, selected: "mila", exclusive: true, distant: true).map(\.rttMs), [75])
        XCTAssertEqual(CloudPingResult.ordered(results, selected: "stoa", exclusive: true, distant: true).map(\.rttMs), [nil])
        XCTAssertEqual(CloudPingResult.ordered(results, selected: "tyob", exclusive: true, distant: false).map(\.rttMs), [107])
        XCTAssertEqual(CloudPingResult.ordered([CloudPingResult(center: centers[0], rttMs: 42)], selected: "tyob", exclusive: false, distant: true).map(\.rttMs), [42])
    }
    func testRejectsMalformedEndpointsAndDuplicateIdentifiers() throws {
        for ip in ["https://sony.com", "127.0.0.1:80", "256.1.1.1", "01.2.3.4", "1.2.3", "1.2.3.4\n"] {
            let object: [[String: Any]] = [["dataCenter": "EU-1", "publicIp": ip, "port": 2053]]
            XCTAssertThrowsError(try CloudDatacenter.decode(JSONSerialization.data(withJSONObject: object)))
        }
        let row: [String: Any] = ["dataCenter": "EU-1", "publicIp": "192.0.2.1", "port": 2053]
        XCTAssertThrowsError(try CloudDatacenter.decode(JSONSerialization.data(withJSONObject: [row, row])))
        XCTAssertThrowsError(try CloudDatacenter.decode(Data("[]".utf8)))
        for port in [0, 65536] {
            XCTAssertThrowsError(try CloudDatacenter.decode(JSONSerialization.data(withJSONObject: [["dataCenter": "EU-1", "publicIp": "192.0.2.1", "port": port]])))
        }
    }
    func testDatacenterChoiceAndWrappedList() throws {
        let wrapped = Data("{\"dataCenters\":[{\"dataCenter\":\"EU-1\",\"publicIp\":\"192.0.2.1\",\"port\":2053},{\"dataCenter\":\"EU-2\",\"publicIp\":\"192.0.2.2\",\"port\":2053}]}".utf8)
        let centers = try CloudDatacenter.decode(wrapped)
        XCTAssertEqual(centers.map(\.id), ["EU-1", "EU-2"])
        XCTAssertEqual(CloudDatacenter.choose(centers, latencies: [:], preferred: nil)?.id, "EU-1")
        XCTAssertEqual(CloudDatacenter.choose(centers, latencies: ["EU-1": 80, "EU-2": 20], preferred: nil)?.id, "EU-2")
        XCTAssertEqual(CloudDatacenter.choose(centers, latencies: ["EU-1": 80, "EU-2": 20], preferred: "EU-1")?.id, "EU-1")
        XCTAssertEqual(CloudDatacenter.choose(centers, latencies: ["EU-1": 80], preferred: "gone")?.id, "EU-1")
    }
    func testDatacenterAddressesAndUnavailableEntries() throws {
        let response = Data("[{\"dataCenter\":\"EU-1\",\"publicIp\":\"ping.example.com\",\"port\":\"2053\"},{\"dataCenter\":\"EU-2\",\"publicIp\":\"\",\"port\":2053}]".utf8)
        let centers = try CloudDatacenter.decode(response)
        XCTAssertEqual(centers.count, 1)
        XCTAssertEqual(centers[0].port, 2053)
        for invalid in ["300.1.1.1", "https://example.com", "example.com/path", "-bad.example.com", "a..example.com"] {
            XCTAssertFalse(CloudDatacenter.validAddress(invalid))
        }
    }
}
