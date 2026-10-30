import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SoleCore

final class SessionsTests: XCTestCase {
    func testASessionOfTheSharedCodeKeepsNoCookiesAndSendsNoneOfItsOwn() {
        let ephemeral = URLSessionConfiguration.ephemeral
        XCTAssertNotNil(ephemeral.httpCookieStorage, "A session's settings keep cookies unless told not to")
        for configuration in [ephemeral, URLSessionConfiguration.default] {
            let session = URLSession.lasting(configuration)
            XCTAssertNil(session.configuration.httpCookieStorage)
            XCTAssertFalse(session.configuration.httpShouldSetCookies)
        }
    }

    func testTheCookieARequestNamesIsTheOneSent() async throws {
        final class Echo: URLProtocol {
            nonisolated(unsafe) static var seen: [String?] = []
            static let lock = NSLock()
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                Echo.lock.withLock { Echo.seen.append(request.value(forHTTPHeaderField: "Cookie")) }
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Set-Cookie": "visitor=1; Path=/; Secure"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Echo.self]
        configuration.httpCookieStorage?.setCookie(HTTPCookie(properties: [.name: "visitor", .value: "1", .domain: "account.example", .path: "/", .secure: "TRUE"])!)
        let session = URLSession.lasting(configuration)
        var request = URLRequest(url: URL(string: "https://account.example/authorize")!)
        request.setValue("npsso=abc", forHTTPHeaderField: "Cookie")
        _ = try await session.plainData(for: request)
        _ = try await session.plainData(for: request)
        let seen = Echo.lock.withLock { Echo.seen }
        XCTAssertEqual(seen, ["npsso=abc", "npsso=abc"])
    }
}
