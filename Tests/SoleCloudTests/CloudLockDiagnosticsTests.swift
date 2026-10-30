import XCTest
@testable import SoleCloud

final class CloudLockDiagnosticsTests: XCTestCase {
    private func keptStrings(_ value: Any) -> [String] {
        if let dictionary = value as? [String: Any] {
            return dictionary.flatMap { key, child -> [String] in
                if key == "value", let text = child as? String { return [text] }
                return keptStrings(child)
            }
        }
        if let array = value as? [Any] { return array.flatMap(keptStrings) }
        return []
    }
    func testTheLockRecordKeepsNoStringsButStatesAndReasons() throws {
        let answer: [String: Any] = [
            "lockAcquired": false, "status": "PENDING", "reason": "otherSessionActive", "retryCount": 2, "waitMs": 123_456_789,
            "sessionId": "secret-session-id", "sessionKey": "secretKeyValue", "accountId": "1234567890123456789", "onlineId": "SecretPlayer",
            "url": "https://example.com/secret", "token": "abcdefABCDEF", "deviceName": "SecretMac", "message": "the other session of SecretPlayer", "title": "SecretGame",
            "hexWord": "deadbeef", "a1b2c3d4e5f6a7b8": "keyed-by-id", "lockedBy": ["clientId": "secret-client", "platform": "PS5", "since": 1_700_000_000, "active": true],
            "errors": [["name": "sessionBusy", "eventCode": "002.2005", "description": "SecretPlayer is playing"]],
            "user": ["name": "SecretName"]
        ]
        let data = try JSONSerialization.data(withJSONObject: answer)
        let entry = CloudLockDiagnostics.entry(status: 200, data: data, headers: ["X-Gaikai-Session": "secret-header-key", "Retry-After": "5", "Content-Type": "application/json"],
                                               forced: true, attempt: 2, elapsedMs: 2100, requestMs: 90)
        let encoded = try JSONSerialization.data(withJSONObject: entry, options: .sortedKeys)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.lowercased().contains("secret"), text)
        for leak in ["1234567890123456789", "abcdefABCDEF", "deadbeef", "a1b2c3d4e5f6a7b8", "keyed-by-id", "example.com", "1700000000", "123456789", "application/json"] {
            XCTAssertFalse(text.contains(leak), leak)
        }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(keptStrings(object)), ["PENDING", "otherSessionActive", "sessionBusy", "002.2005"])
        let fields = try XCTUnwrap((object["answer"] as? [String: Any])?["fields"] as? [String: [String: Any]])
        XCTAssertEqual(fields["lockAcquired"]?["value"] as? Bool, false)
        XCTAssertEqual(fields["lockAcquired"]?["type"] as? String, "boolean")
        XCTAssertEqual(fields["retryCount"]?["value"] as? Int, 2)
        XCTAssertNil(fields["waitMs"]?["value"], "A large number may be an identifier")
        XCTAssertEqual(fields["sessionId"]?["type"] as? String, "string(17)")
        XCTAssertEqual((fields["lockedBy"]?["fields"] as? [String: [String: Any]])?["active"]?["value"] as? Bool, true)
        XCTAssertEqual(object["retryAfter"] as? Int, 5)
        XCTAssertEqual(object["headers"] as? [String], ["content-type", "retry-after", "x-gaikai-session"])
        XCTAssertEqual(object["forced"] as? Bool, true); XCTAssertEqual(object["attempt"] as? Int, 2)
        XCTAssertEqual(object["elapsedMs"] as? Int, 2100); XCTAssertEqual(object["status"] as? Int, 200)
    }
    func testAnswersThatAreNotObjects() {
        XCTAssertEqual(CloudLockDiagnostics.shape(Data())["format"] as? String, "empty")
        XCTAssertEqual(CloudLockDiagnostics.shape(Data("<html>secret</html>".utf8))["format"] as? String, "non-json")
        XCTAssertEqual(CloudLockDiagnostics.shape(Data(#""secret""#.utf8))["format"] as? String, "string(6)")
        XCTAssertEqual(CloudLockDiagnostics.shape(Data("[1,2]".utf8))["format"] as? String, "array(2)")
    }
}
