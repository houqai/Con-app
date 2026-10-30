import XCTest
import SoleCloud
import SoleEngine
@testable import SoleLogic

final class CloudProbeRecordTests: XCTestCase {
    private func centers() throws -> [CloudDatacenter] {
        try CloudDatacenter.decode(Data(#"[{"dataCenter":"fra","publicIp":"1.2.3.4","port":2053},{"dataCenter":"ams","publicIp":"5.6.7.8","port":2053},{"dataCenter":"lon","publicIp":"9.9.9.9","port":2053}]"#.utf8))
    }

    func testTheRecordKeepsTheStages() throws {
        let measured = CloudNetworkProbe.Report(measurement: .init(rttMs: 20, mtuIn: 1400, mtuOut: 1300), stage: 7, status: 0, engineStage: 6)
        let failed = CloudNetworkProbe.Report(measurement: nil, stage: 0, status: 3, engineStage: 1)
        let record = CloudAuthorization.probeRecord(try centers(), reports: ["fra": measured, "ams": failed], durationMs: 1234.5)
        XCTAssertNil(record["engine"])
        XCTAssertEqual(record["durationMs"] as? Int, 1234)
        let rows = try XCTUnwrap(record["datacenters"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0]["rttMs"] as? Int, 20); XCTAssertEqual(rows[0]["mtuOut"] as? Int, 1300); XCTAssertEqual(rows[0]["engineStage"] as? Int, 6)
        XCTAssertEqual(rows[1]["status"] as? Int, 3); XCTAssertNil(rows[1]["rttMs"]); XCTAssertEqual(rows[1]["stage"] as? Int, 0)
        XCTAssertEqual(rows[2]["completed"] as? Bool, false, "a test still running at the deadline")
        XCTAssertFalse(String(describing: record).contains("1.2.3.4"), "no addresses")
    }
}
