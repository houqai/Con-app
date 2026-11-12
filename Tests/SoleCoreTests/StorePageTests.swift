import XCTest
@testable import SoleCore

final class StorePageTests: XCTestCase {
    func testEndpointAcceptsOnlyKnownLocalesAndPositiveConcepts() {
        XCTAssertEqual(StorePage.endpoint(conceptID: 10000368, locale: "en-us")?.absoluteString, "https://store.playstation.com/en-us/concept/10000368")
        XCTAssertNil(StorePage.endpoint(conceptID: 0, locale: "en-us"))
        XCTAssertNil(StorePage.endpoint(conceptID: 1, locale: "../admin"))
    }
    func testACatalogPlaceholderIsReplacedByTheStoreFullGame() {
        let html = Data(#"{"cache":{"Concept:10000237":{"products":[{"__ref":"Product:UP0001-PPSA01491_00-GAME000000000000"},{"__ref":"Product:UP0001-PPSA01491_00-EDITIONDELUXE000"}],"defaultProduct":{"__ref":"Product:UP0001-PPSA01491_00-GAME000000000000"}},"Product:UP0001-PPSA01491_00-GAME000000000000":{"id":"UP0001-PPSA01491_00-GAME000000000000","platforms":["PS5"],"storeDisplayClassification":"FULL_GAME"},"Product:UP0001-PPSA01491_00-EDITIONDELUXE000":{"id":"UP0001-PPSA01491_00-EDITIONDELUXE000","platforms":["PS5"],"storeDisplayClassification":"PREMIUM_EDITION"}}}"#.utf8)
        let page = Data("<script type=\"application/json\">".utf8) + html + Data("</script>".utf8)
        XCTAssertEqual(StorePage.ps5FullGame(page, conceptID: 10000237), "UP0001-PPSA01491_00-GAME000000000000")
        let split = Data(#"<script type="application/json">{"cache":{"Concept:10004911":{"defaultProduct":{"__ref":"Product:UP1018-PPSA07570_00-MKONE00000000000"}}}}</script><script type="application/json">{"cache":{"Concept:10004911":{"products":[{"__ref":"Product:UP1018-PPSA07570_00-MKONE00000000000"}]},"Product:UP1018-PPSA07570_00-MKONE00000000000":{"id":"UP1018-PPSA07570_00-MKONE00000000000","platforms":["PS5"],"storeDisplayClassification":"FULL_GAME"}}}</script>"#.utf8)
        XCTAssertEqual(StorePage.ps5FullGame(split, conceptID: 10004911), "UP1018-PPSA07570_00-MKONE00000000000")
    }
}
