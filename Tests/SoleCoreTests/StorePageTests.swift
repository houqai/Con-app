import XCTest
@testable import SoleCore

final class StorePageTests: XCTestCase {
    func testEndpointAcceptsOnlyKnownLocalesAndPositiveConcepts() {
        XCTAssertEqual(StorePage.endpoint(conceptID: 10000368, locale: "en-us")?.absoluteString, "https://store.playstation.com/en-us/concept/10000368")
        XCTAssertNil(StorePage.endpoint(conceptID: 0, locale: "en-us"))
        XCTAssertNil(StorePage.endpoint(conceptID: 1, locale: "../admin"))
    }
}
