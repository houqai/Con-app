import XCTest
@testable import SoleCore

final class PSNIdentityTests: XCTestCase {
    private func jwt(_ payload: String) -> String {
        let encoded = Data(payload.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "e30." + encoded + ".test"
    }

    func testPreservesAccountIDsLargerThanJavaScriptSafeInteger() {
        XCTAssertEqual(PSNIdentity.accountID(fromJWT: jwt(#"{"user_id":"18446744073709551615"}"#)), "18446744073709551615")
        XCTAssertEqual(PSNIdentity.accountID(fromJWT: jwt(#"{"account_id":18446744073709551614}"#)), "18446744073709551614")
    }

    func testRejectsMissingMalformedAndUnsafeAccountIDs() {
        for value in ["", "me", "../profiles", "-1", "1.2", "1e4", "0", "18446744073709551616"] {
            XCTAssertNil(PSNIdentity.normalizedAccountID(value))
        }
        XCTAssertNil(PSNIdentity.accountID(fromJWT: "not-a-jwt"))
        XCTAssertNil(PSNIdentity.accountID(fromJWT: jwt(#"{"user_id":true}"#)))
        XCTAssertNil(PSNIdentity.accountID(fromJWT: jwt(#"{"sub":"opaque-uuid"}"#)))
    }

    func testTheAccountOfATokenInfoAnswerIsATextOrAWholeNumber() {
        XCTAssertEqual(PSNIdentity.accountID(fromTokenInfo: Data(#"{"user_id":"1234567890123456789","scopes":["a"],"nested":{"user_id":"9"}}"#.utf8)), "1234567890123456789")
        XCTAssertEqual(PSNIdentity.accountID(fromTokenInfo: Data(#"{"user_id":1234567890123456789}"#.utf8)), "1234567890123456789")
        XCTAssertEqual(PSNIdentity.accountID(fromTokenInfo: Data(#"{"user_id":18446744073709551615}"#.utf8)), "18446744073709551615", "The whole range of an account number")
        for bad in [#"{"user_id":true}"#, #"{"user_id":0}"#, #"{"user_id":-5}"#, #"{"user_id":1.5}"#, #"{"user_id":null}"#, #"{"user_id":["1"]}"#, #"{"account_id":"7"}"#, "[1]", "not json"] {
            XCTAssertNil(PSNIdentity.accountID(fromTokenInfo: Data(bad.utf8)), bad)
        }
    }
}
