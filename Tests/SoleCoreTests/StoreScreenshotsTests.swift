import XCTest
@testable import SoleCore

final class StoreScreenshotsTests: XCTestCase {
    func testRealDemonsSoulsMediaIncludesOnlyScreenshots() {
        let json = #"{"cache":{"Concept:10000368":{"media":[{"__typename":"Media","type":"IMAGE","role":"BACKGROUND_LAYER_ART","url":"https://image.api.playstation.com/vulcan/img/rnd/202011/1717/ERyxTrhG8olx7M5a8QdNjNGy.png"},{"__typename":"Media","type":"IMAGE","role":"FOUR_BY_THREE_BANNER","url":"https://image.api.playstation.com/vulcan/img/rnd/202011/1717/M8cxD6UPmsU551lmNq9Lat9Y.png"},{"__typename":"Media","type":"IMAGE","role":"GAMEHUB_COVER_ART","url":"https://image.api.playstation.com/vulcan/img/rnd/202011/1717/brIXKBE5BqYgBSrsDn6Wo18O.png"},{"__typename":"Media","type":"IMAGE","role":"HERO_CHARACTER","url":"https://image.api.playstation.com/vulcan/img/rnd/202011/1717/NjoTQ0BFAurDiLk1ri39wqyb.png"},{"__typename":"Media","type":"IMAGE","role":"LOGO","url":"https://image.api.playstation.com/vulcan/img/rnd/202011/1717/G7eHdFjDMX81CJAc3SbtMRLs.png"},{"__typename":"Media","type":"IMAGE","role":"PORTRAIT_BANNER","url":"https://image.api.playstation.com/vulcan/img/rnd/202011/1717/qHFrrJINxIfsvIyudYAyjfDq.png"},{"__typename":"Media","type":"IMAGE","role":"SCREENSHOT","url":"https://image.api.playstation.com/vulcan/ap/rnd/202010/0821/OtTU8V9BfVqiy4jp0QhHp8ad.jpg"},{"__typename":"Media","type":"IMAGE","role":"SCREENSHOT","url":"https://image.api.playstation.com/vulcan/ap/rnd/202010/0821/NE92EYZjGR8hU8ZcNDgEYEX1.jpg"},{"__typename":"Media","type":"IMAGE","role":"SCREENSHOT","url":"https://image.api.playstation.com/vulcan/ap/rnd/202010/0821/lK4tpxDNLfOxHly1yE5ceKNt.jpg"},{"__typename":"Media","type":"IMAGE","role":"SCREENSHOT","url":"https://image.api.playstation.com/vulcan/ap/rnd/202010/0821/s1gIFpXqw8t18gzshEHkv8r2.jpg"},{"__typename":"Media","type":"IMAGE","role":"SCREENSHOT","url":"https://image.api.playstation.com/vulcan/ap/rnd/202010/0821/qZUNNzWOxkdhay3pp6HzRSQ3.jpg"},{"__typename":"Media","type":"IMAGE","role":"SCREENSHOT","url":"https://image.api.playstation.com/vulcan/ap/rnd/202010/0821/p3BNVCDOeLpb3bWAptk2Hi2t.jpg"},{"__typename":"Media","type":"IMAGE","role":"SCREENSHOT","url":"https://image.api.playstation.com/vulcan/ap/rnd/202010/0821/sYFQ266gczqGyso9d8PjJ1Al.jpg"},{"__typename":"Media","type":"IMAGE","role":"MASTER","url":"https://image.api.playstation.com/vulcan/img/rnd/202011/1717/GemRaOZaCMhGxQ9dRhnQQyT5.png"}]}}}"#
        let html = Data(("<script type=\"application/json\">" + json + "</script>").utf8)
        let images = StoreScreenshots.parse(html, conceptID: 10000368)
        XCTAssertEqual(images.count, 6)
        XCTAssertEqual(images.first?.lastPathComponent, "OtTU8V9BfVqiy4jp0QhHp8ad.jpg")
        XCTAssertEqual(images.last?.lastPathComponent, "p3BNVCDOeLpb3bWAptk2Hi2t.jpg")
        XCTAssertEqual(Set(images).count, 6)
        XCTAssertTrue(images.allSatisfy { $0.pathExtension == "jpg" })
        XCTAssertTrue(StoreScreenshots.parse(html, conceptID: 42).isEmpty)
    }

    func testRejectsUntrustedURLsAndDeduplicatesDefaultProduct() {
        let json = #"{"cache":{"Concept:42":{"defaultProduct":{"__ref":"Product:game"},"media":[{"type":"IMAGE","role":"SCREENSHOT","url":"https://image.api.playstation.com/a.jpg"},{"type":"IMAGE","role":"SCREENSHOT","url":"https://unrelated.example/a.jpg"},{"type":"IMAGE","role":"SCREENSHOT","url":"http://image.api.playstation.com/a.jpg"}]},"Product:game":{"media":[{"type":"IMAGE","role":"SCREENSHOT","url":"https://image.api.playstation.com/a.jpg"},{"type":"VIDEO","role":"SCREENSHOT","url":"https://image.api.playstation.com/video.mp4"}]},"Concept:999":{"media":[{"type":"IMAGE","role":"SCREENSHOT","url":"https://image.api.playstation.com/other.jpg"}]}}}"#
        let html = Data(("<script type=\"application/json\">" + json + "</script>").utf8)
        XCTAssertEqual(StoreScreenshots.parse(html, conceptID: 42).map(\.absoluteString), ["https://image.api.playstation.com/a.jpg"])
        XCTAssertTrue(StoreScreenshots.parse(Data("broken".utf8), conceptID: 42).isEmpty)
    }
}
