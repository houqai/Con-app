import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import SoleCloud

final class SonySSOTests: XCTestCase {
    private func cookie(_ domain: String = ".sony.com", value: String = "test-credential", secure: Bool = true, expires: Date? = nil) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: "npsso", .value: value, .domain: domain, .path: "/"]
        if secure { properties[.secure] = "TRUE" }
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)!
    }
    func testRejectsUntrustedInsecureAndExpiredCookies() {
        let now = Date()
        XCTAssertNil(SonySSO.credential(from: [cookie("sony.com.attacker.example")], now: now))
        XCTAssertNil(SonySSO.credential(from: [cookie("evilsony.com")], now: now))
        XCTAssertNil(SonySSO.credential(from: [cookie("ca.account.sony.com", secure: false)], now: now))
        XCTAssertNil(SonySSO.credential(from: [cookie(expires: now.addingTimeInterval(-1))], now: now))
        XCTAssertFalse(SonySSO.validValue("secret; injected=other"))
        XCTAssertFalse(SonySSO.validValue("secret\r\nCookie: other"))
    }
    func testRejectsConflictingAccountsAndPreservesEarliestExpiry() throws {
        let now = Date()
        XCTAssertNil(SonySSO.credential(from: [cookie(value: "first"), cookie("ca.account.sony.com", value: "second")], now: now))
        let expiration = now.addingTimeInterval(60)
        let credential = try XCTUnwrap(SonySSO.credential(from: [cookie(expires: now.addingTimeInterval(120)), cookie("ca.account.sony.com", expires: expiration)], now: now))
        XCTAssertEqual(credential.expiresAt.timeIntervalSince1970, expiration.timeIntervalSince1970, accuracy: 1)
        XCTAssertTrue(credential.isValid)
        let roundTrip = try JSONDecoder().decode(SonySSO.self, from: JSONEncoder().encode(credential))
        XCTAssertEqual(roundTrip.value, credential.value)
    }

    func testACookieAWebViewSendsOnlyOverHTTPSIsTheSecureOne() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sso = SonySSO.credential(sentSecurely: "dtCookie=v_4; npsso=AbC-123_x.y; lang=en", sentPlainly: "dtCookie=v_4; lang=en", now: now)
        XCTAssertEqual(sso?.value, "AbC-123_x.y")
        XCTAssertEqual(sso?.expiresAt, now.addingTimeInterval(86400))
        XCTAssertNil(SonySSO.credential(sentSecurely: "npsso=AbC", sentPlainly: "npsso=AbC", now: now))
        XCTAssertNil(SonySSO.credential(sentSecurely: "npsso=one; npsso=two", sentPlainly: "", now: now))
        XCTAssertNotNil(SonySSO.credential(sentSecurely: "npsso=one; npsso=one", sentPlainly: "", now: now))
        XCTAssertNil(SonySSO.credential(sentSecurely: "lang=en", sentPlainly: "", now: now))
        XCTAssertNil(SonySSO.credential(sentSecurely: "", sentPlainly: "", now: now))
        XCTAssertNil(SonySSO.credential(sentSecurely: "npsso=has space", sentPlainly: "", now: now))
        XCTAssertNil(SonySSO.credential(sentSecurely: "xnpsso=AbC; npsso2=AbC", sentPlainly: "", now: now), "Only a cookie named exactly npsso")
        XCTAssertNil(SonySSO.credential(sentSecurely: "npsso=a=b", sentPlainly: "", now: now), "Tokens never contain '='")
    }
}
