import XCTest
@testable import SoleCore

final class StoreStreamingTests: XCTestCase {
    func testExactPS5ProductNeedsExplicitStreamingNotice() {
        let product = "UP9000-PPSA01969_00-DEATHSTRADCDDE01"
        let fixture = Data(#"<script type="application/json">{"cache":{"Concept:234585":{},"Product:UP9000-PPSA01969_00-DEATHSTRADCDDE01":{"platforms":["PS5"],"compatibilityNoticesByPlatform":{"Common":[{"type":"STREAMING_SUPPORTED","value":"OPTIONAL","targetPlatforms":["PS5","DWC"]}]}}}}</script>"#.utf8)
        XCTAssertTrue(StoreStreaming.supportsPS5(fixture, conceptID: 234585, productID: product))
        XCTAssertFalse(StoreStreaming.supportsPS5(fixture, conceptID: 1, productID: product))
        XCTAssertFalse(StoreStreaming.supportsPS5(fixture, conceptID: 234585, productID: "other"))
        XCTAssertFalse(StoreStreaming.supportsPS5(Data(String(decoding: fixture, as: UTF8.self).replacingOccurrences(of: "OPTIONAL", with: "UNSUPPORTED").utf8), conceptID: 234585, productID: product))
    }
}
