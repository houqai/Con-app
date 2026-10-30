import XCTest
@testable import SoleCloud

final class PSPlusPCTests: XCTestCase {
    func testScreenshotsKeepSixImagesAndRejectVideosAndUntrustedURLs() {
        let images = (0..<9).map { ["type": 26, "url": "https://nsx.np.dl.playstation.net/\($0).jpg"] as [String: Any] }
        let urls = PSPlusPCService.screenshotURLs(["promomedia": [["materials": [["urls": images + [images[0], ["type": 28, "url": "https://nsx.np.dl.playstation.net/video.mp4"], ["type": 26, "url": "https://evil.test/p.jpg"]]]]]]])
        XCTAssertEqual(urls.count, 6)
        XCTAssertEqual(urls.last?.lastPathComponent, "5.jpg")
        XCTAssertTrue(PSPlusPCService.screenshotURLs(["promomedia": [["materials": [["urls": [["type": 26, "url": "http://nsx.np.dl.playstation.net/a.jpg"], ["type": 28, "url": "https://nsx.np.dl.playstation.net/a.mp4"]]]]]]]).isEmpty)
    }
    func testModernScreenshotListIsSupported() {
        let rows = (0..<8).map { ["type": "SCREENSHOT", "typeId": 4, "url": "https://vulcan.dl.playstation.net/\($0).jpg"] as [String: Any] }
        let result = PSPlusPCService.screenshotURLs(["mediaList": ["screenshots": rows, "previews": [["type": "PREVIEW", "url": "https://vulcan.dl.playstation.net/a.mp4"]]]])
        XCTAssertEqual(result.count, 6)
        XCTAssertEqual(result.first?.lastPathComponent, "0.jpg")
    }
    func testPS3StreamingEntitlementIsSelectedWithoutMixingPlatforms() {
        let product = "UP0101-NPUB30505_00-CVHDZDLCZUNLOCKZ"
        let object: [String: Any] = ["default_sku": ["entitlements": [["id": "UP0101-NPUB30505_00-PSNW01", "license_type": 4], ["id": "UP0101-CUSA00900_00-GAME", "license_type": 4]]]]
        XCTAssertEqual(PSPlusPCService.entitlement(object, productID: product), "UP0101-NPUB30505_00-PSNW01")
        XCTAssertNil(PSPlusPCService.title(["id": "UP0101-NPUJ00000_00-GAME", "name": "PS1", "playable_platform": ["PS3"]]))
        XCTAssertEqual(PSPlusPCService.title(["id": product, "name": "Castlevania", "playable_platform": ["PS3™"]])?.backend, .ps3)
    }
    func testCallbackRejectsWrongHostStateAndDuplicateCodes() throws {
        let url = URL(string: PSPlusPCService.redirect + "?code=test&state=expected")!
        XCTAssertEqual(try PSPlusPCService.code(from: url, state: "expected"), "test")
        for text in ["https://example.com/?code=test&state=expected", PSPlusPCService.redirect + "?code=a&code=b&state=expected", PSPlusPCService.redirect + "?code=a&state=wrong", PSPlusPCService.redirect + "?code=a%0A&state=expected"] {
            XCTAssertThrowsError(try PSPlusPCService.code(from: URL(string: text)!, state: "expected"))
        }
    }
    func testCatalogAcceptsOnlyPS4TitlesAndTrustedStoreEndpoints() {
        XCTAssertNotNil(PSPlusPCService.title(["id": "UP9000-CUSA00900_00-BLOODBORNE000000", "name": "Bloodborne", "playable_platform": ["PS4"]]))
        XCTAssertNotNil(PSPlusPCService.title(["id": "UP9000-CUSA00900_00-BLOODBORNE000000", "name": "Bloodborne", "metadata": ["playable_platform": ["values": ["PS4"]]]]))
        XCTAssertEqual(PSPlusPCService.title(["id": "UP9000-NPUB00000_00-GAME", "name": "PS3", "playable_platform": ["PS3"]])?.backend, .ps3)
        XCTAssertNil(PSPlusPCService.storeURL("https://example.com/store/api/pcnow/00_09_000/container/US/en/19/title"))
        XCTAssertNil(PSPlusPCService.storeURL("https://psnow.playstation.com/kamaji/api/private"))
    }
    func testActivationAcceptsOnlyExactlyOneZeroPriceExpectedStreamingSKU() {
        let sku = "UP9000-CUSA00900_00-BLOODBORNE000000-UC01"
        func preview(_ price: Any, _ items: [[String: Any]]) -> [String: Any] {
            ["header": ["status_code": "0x0000"], "data": ["cart": ["total_price_value": price, "items": items]]]
        }
        XCTAssertEqual(PSPlusPCService.freeStreamingSKU(preview(0, [["sku_id": sku]]), expectedSKU: sku), sku)
        XCTAssertNil(PSPlusPCService.freeStreamingSKU(preview(1, [["sku_id": sku]]), expectedSKU: sku))
        XCTAssertNil(PSPlusPCService.freeStreamingSKU(preview(0, [["sku_id": "OTHER"]]), expectedSKU: sku))
        XCTAssertNil(PSPlusPCService.freeStreamingSKU(preview(0, [["sku_id": sku], ["sku_id": sku]]), expectedSKU: sku))
        XCTAssertNil(PSPlusPCService.freeStreamingSKU([:], expectedSKU: sku))
    }

    func testStreamingEntitlementWinsOverPurchaseAndDLCOrDifferentTitleCannotMatch() {
        let product = "UP9000-CUSA00900_00-BLOODBORNE000000"
        let rows: [[String: Any]] = [
            ["id": product, "feature_type": 3],
            ["id": "UP9000-CUSA00900_00-STREAM", "license_type": 4],
            ["id": "UP9000-CUSA00900_00-DLC", "feature_type": 1],
            ["id": "UP9000-CUSA99999_00-STREAM", "license_type": 4]
        ]
        XCTAssertEqual(PSPlusPCService.entitlement(["default_sku": ["entitlements": rows]], productID: product), "UP9000-CUSA00900_00-STREAM")
        XCTAssertNil(PSPlusPCService.entitlement(["default_sku": ["entitlements": Array(rows.suffix(2))]], productID: product))
    }
}
