import XCTest
@testable import SoleCore

final class CloudCatalogTests: XCTestCase {
    func testIncludesOnlyExplicitlyStreamableConceptsAndDeduplicates() throws {
        let fixture = Data(#"[{"games":[{"conceptId":2,"name":"Zeta","streamingSupported":true,"productId":"EP0000-PPSA00002_00-GAME000000000000"},{"conceptId":1,"name":"Alpha","streamingSupported":true},{"conceptId":3,"name":"Not streaming","streamingSupported":false},{"conceptId":4,"name":"Unknown"}]},{"games":[{"conceptId":2,"name":"Duplicate","streamingSupported":true}]}]"#.utf8)
        let titles = try CloudCatalog.decode(fixture)
        XCTAssertEqual(titles.map(\.id), ["concept:1", "concept:2"])
        XCTAssertEqual(titles[1].productId, "EP0000-PPSA00002_00-GAME000000000000")
        XCTAssertEqual(titles[0].storeURL.host, "store.playstation.com")
    }
    func testRejectsUnexpectedResponseAndLocaleInjection() {
        XCTAssertThrowsError(try CloudCatalog.decode(Data(#"{"error":"unauthorized"}"#.utf8)))
        XCTAssertNil(CloudCatalog.endpoint(locale: "../../other"))
        XCTAssertNil(CloudCatalog.endpoint(locale: "en-us&categoryList=other"))
        XCTAssertEqual(CloudCatalog.endpoint(locale: "en-us")?.host, "www.playstation.com")
    }
    func testInsecureCoverDoesNotBecomeAFileRequest() throws {
        let titles = try CloudCatalog.decode(Data(#"[{"games":[{"conceptId":1,"name":"Test","imageUrl":"file:///tmp/image.jpg","streamingSupported":true}]}]"#.utf8))
        XCTAssertNil(titles[0].artworkURL)
    }
}
