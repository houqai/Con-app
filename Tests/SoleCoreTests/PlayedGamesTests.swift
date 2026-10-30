import XCTest
@testable import SoleCore

final class PlayedGamesTests: XCTestCase {
    func testParsesMinimalAndLocalizedTitlesWithoutInferringCloudEntitlement() throws {
        let data = Data(#"{"titles":[{"titleId":"PPSA12345_00","name":"Game","localizedName":"Spiel","category":"ps5_native_game","imageUrl":"https://images.example.com/game.jpg"},{"titleId":"CUSA12345_00","name":"Legacy"}],"nextOffset":2,"totalItemCount":2}"#.utf8)
        let page = try JSONDecoder().decode(PlayedGamesPage.self, from: data)
        XCTAssertEqual(page.titles.count, 2)
        XCTAssertEqual(page.titles[0].displayName, "Spiel")
        XCTAssertEqual(page.titles[0].platform, "PS5")
        XCTAssertEqual(page.titles[1].platform, "PlayStation")
        XCTAssertNil(page.titles[1].artworkURL)
        XCTAssertEqual(page.nextOffset, 2)
    }

    func testRejectsInsecureArtworkAndUsesSafeFallback() throws {
        let data = Data(#"{"titles":[{"titleId":"1","name":"Game","localizedName":" ","localizedImageUrl":"file:///tmp/image.jpg","imageUrl":"https://images.example.com/game.jpg"},{"titleId":"2","name":"Game","imageUrl":"http://images.example.com/game.jpg"}]}"#.utf8)
        let page = try JSONDecoder().decode(PlayedGamesPage.self, from: data)
        XCTAssertEqual(page.titles[0].displayName, "Game")
        XCTAssertEqual(page.titles[0].artworkURL?.scheme, "https")
        XCTAssertNil(page.titles[1].artworkURL)
    }

    func testLastPlayedIsReadWithAndWithoutFractionsOfASecond() throws {
        let data = Data(#"{"titles":[{"titleId":"1","name":"A","lastPlayedDateTime":"2026-01-01T00:00:00Z"},{"titleId":"2","name":"B","lastPlayedDateTime":"2026-01-01T00:00:00.250Z"},{"titleId":"3","name":"C"},{"titleId":"4","name":"D","lastPlayedDateTime":"yesterday"}]}"#.utf8)
        let titles = try JSONDecoder().decode(PlayedGamesPage.self, from: data).titles
        XCTAssertEqual(titles[0].lastPlayed?.timeIntervalSince1970, 1_767_225_600)
        XCTAssertEqual(try XCTUnwrap(titles[1].lastPlayed?.timeIntervalSince1970), 1_767_225_600.25, accuracy: 0.001)
        XCTAssertEqual(titles[1].lastPlayedDateTime, "2026-01-01T00:00:00.250Z")
        XCTAssertNil(titles[2].lastPlayed)
        XCTAssertNil(titles[3].lastPlayed)
    }

    func testErrorResponseIsNotTreatedAsAnEmptyLibrary() {
        XCTAssertThrowsError(try JSONDecoder().decode(PlayedGamesPage.self, from: Data(#"{"error":{"message":"Unauthorized"}}"#.utf8)))
    }
}
