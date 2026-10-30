import XCTest
@testable import SoleCore

final class PSNCallbackTests: XCTestCase {
    func testAcceptsExactCallbackAndDecodesCode() throws {
        let url = URL(string: PSNCallback.redirect + "?state=nonce&code=a%2Bb%26c")!
        XCTAssertEqual(try PSNCallback.code(from: url, expectedState: "nonce"), "a+b&c")
        XCTAssertEqual(try PSNCallback.code(from: URL(string: PSNCallback.redirect + "/?state=nonce&code=test")!, expectedState: "nonce"), "test")
    }

    func testRejectsForgedAmbiguousOrFailedCallback() {
        let invalid = [
            "https://redirect?state=nonce&code=test",
            "com.scee.psxandroid.scecompcall://attacker?state=nonce&code=test",
            PSNCallback.redirect + "?state=wrong&code=test",
            PSNCallback.redirect + "?state=nonce&state=wrong&code=test",
            PSNCallback.redirect + "?state=nonce&code=first&code=second",
            PSNCallback.redirect + "?state=nonce&code=",
            PSNCallback.redirect + "?state=nonce&code=%20",
            PSNCallback.redirect + "?code=test",
            PSNCallback.redirect + "?state=nonce&code=test&error=access_denied",
            PSNCallback.redirect + "/other?state=nonce&code=test",
            PSNCallback.redirect + "?state=nonce&code=test#fragment",
            "com.scee.psxandroid.scecompcall://name@redirect?state=nonce&code=test",
            "com.scee.psxandroid.scecompcall://redirect:80?state=nonce&code=test"
        ]
        for candidate in invalid {
            XCTAssertThrowsError(try PSNCallback.code(from: URL(string: candidate)!, expectedState: "nonce"), candidate)
        }
    }

    func testFormEncodingDoesNotTurnCodeIntoAdditionalFields() throws {
        let data = PSNCallback.formBody(["code": "a+b&grant_type=evil /✓", "grant_type": "authorization_code"])
        let body = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(body, "code=a%2Bb%26grant_type%3Devil%20%2F%E2%9C%93&grant_type=authorization_code")
        let fields = URLComponents(string: "https://example.com/?" + body)!.queryItems!
        XCTAssertEqual(fields.count, 2)
        XCTAssertEqual(fields.first?.value, "a+b&grant_type=evil /✓")
    }
}
