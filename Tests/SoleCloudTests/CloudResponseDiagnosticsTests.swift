import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import SoleCloud

final class CloudResponseDiagnosticsTests: XCTestCase {
    func testSummaryDoesNotPersistResponseSecretsOrArbitraryKeys() throws {
        let response = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 403, httpVersion: nil, headerFields: ["Server": "CloudFront", "X-Gaikai-Session": "secret-session"])!
        let data = try JSONSerialization.data(withJSONObject: [
            "secret-key-name": "secret-token", "access_token": "secret-access",
            "errors": [["componentCode": 4153, "message": "Invalid entitlement: secret-entitlement", "code": "secret-code"]]
        ])
        let encoded = try XCTUnwrap(CloudResponseDiagnostics.summary(status: 403, data: data, response: response))
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("secret"))
        XCTAssertFalse(text.contains("access_token"))
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(result["categories"] as? [String], ["entitlement", "invalid"])
        XCTAssertEqual(result["codes"] as? [String: String], ["errors[].componentCode": "4153"])
        XCTAssertEqual(result["cloudfront"] as? Bool, true)
    }

    func testPingLimitRefusalKeepsCategoryWithoutResponseText() throws {
        let body = Data(#"{"componentCode":"002","errors":[{"description":"No data centers exist with ping results between 0 and 80","eventCode":"002.0019"}],"httpCode":400}"#.utf8)
        let response = HTTPURLResponse(url: URL(string: "https://cc.prod.gaikai.com/v1/sessions/s/datacenters/select")!, statusCode: 400, httpVersion: nil, headerFields: [:])!
        let summary = try XCTUnwrap(CloudResponseDiagnostics.summary(status: 400, data: body, response: response))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: summary) as? [String: Any])
        XCTAssertEqual(object["categories"] as? [String], ["data center", "ping"])
        XCTAssertEqual((object["codes"] as? [String: String])?["errors[].eventCode"], "002.0019")
        XCTAssertFalse(String(decoding: summary, as: UTF8.self).contains("between"))
    }
    func testNumericCodesSupportNegativeValuesWithoutAcceptingStrings() {
        XCTAssertTrue(CloudResponseDiagnostics.numericCode("-4153"))
        XCTAssertTrue(CloudResponseDiagnostics.numericCode("002"))
        XCTAssertTrue(CloudResponseDiagnostics.numericCode("0002000e"))
        XCTAssertTrue(CloudResponseDiagnostics.numericCode("002.2001"))
        for value in ["", "-", "--2", "+2", "2.5", "secret-value", "12\n34"] {
            XCTAssertFalse(CloudResponseDiagnostics.numericCode(value))
        }
    }
    func testOversizedAndNonJSONResponses() throws {
        let response = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 403, httpVersion: nil, headerFields: nil)!
        XCTAssertNil(CloudResponseDiagnostics.summary(status: 403, data: Data(repeating: 0, count: 2_000_000), response: response))
        let encoded = try XCTUnwrap(CloudResponseDiagnostics.summary(status: 403, data: Data("<html>secret-token</html>".utf8), response: response))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("secret-token"))
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(result["format"] as? String, "non-json")
    }
}
