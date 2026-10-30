import XCTest
@testable import SoleCore

final class TrophiesTests: XCTestCase {
    func testTheSummaryGivesTheLevelItsProgressAndTheTrophiesByGrade() throws {
        let data = Data(#"{"accountId":"1234567890123456789","trophyLevel":432,"progress":33,"tier":5,"earnedTrophies":{"bronze":2234,"silver":557,"gold":165,"platinum":47}}"#.utf8)
        let summary = try XCTUnwrap(TrophySummary.decode(data))
        XCTAssertEqual(summary.level, 432)
        XCTAssertEqual(summary.progress, 33)
        XCTAssertEqual(summary.tier, 5)
        XCTAssertEqual(summary.earned, TrophyCounts(platinum: 47, gold: 165, silver: 557, bronze: 2234))
        XCTAssertEqual(summary.earned.total, 3003)
    }

    func testASummaryWithoutALevelIsNoSummary() {
        XCTAssertNil(TrophySummary.decode(Data(#"{"error":{"referenceId":"x","code":2240526,"message":"Not permitted"}}"#.utf8)))
        XCTAssertNil(TrophySummary.decode(Data("not json".utf8)))
        XCTAssertNil(TrophySummary.decode(Data(#"{"trophyLevel":true}"#.utf8)), "A switch is not a number")
        let fresh = TrophySummary.decode(Data(#"{"trophyLevel":1,"progress":140,"tier":1}"#.utf8))
        XCTAssertEqual(fresh, TrophySummary(level: 1, progress: 100, tier: 1, earned: TrophyCounts()))
    }

    func testTheListsComeLatestFirstWithTheirProgress() {
        let data = Data(#"""
        {"trophyTitles":[
          {"npServiceName":"trophy","npCommunicationId":"NPWR00001_00","trophySetVersion":"01.00","trophyTitleName":"Older Game","trophyTitleDetail":"Trophies","trophyTitleIconUrl":"https://image.api.playstation.com/trophy/np/NPWR00001_00_00ABC/1.PNG","trophyTitlePlatform":"PS4","hasTrophyGroups":false,"definedTrophies":{"bronze":40,"silver":8,"gold":2,"platinum":1},"progress":12,"earnedTrophies":{"bronze":5,"silver":0,"gold":0,"platinum":0},"hiddenFlag":false,"lastUpdatedDateTime":"2025-03-01T10:00:00Z"},
          {"npServiceName":"trophy2","npCommunicationId":"NPWR00002_00","trophySetVersion":"01.00","trophyTitleName":"Newer Game","trophyTitleIconUrl":"https://image.api.playstation.com/trophy/np/NPWR00002_00_00DEF/2.png","trophyTitlePlatform":"PS5","hasTrophyGroups":true,"trophyGroupCount":2,"definedTrophies":{"bronze":41,"silver":6,"gold":3,"platinum":1},"progress":100,"earnedTrophies":{"bronze":41,"silver":6,"gold":3,"platinum":1},"hiddenFlag":false,"lastUpdatedDateTime":"2026-10-12T18:04:31.52Z"},
          {"npCommunicationId":"NPWR00003_00","trophyTitleName":"No Icon","trophyTitleIconUrl":"http://image.api.playstation.com/x.png","trophyTitlePlatform":"PS5,PSPC","progress":"7"},
          {"npCommunicationId":"","trophyTitleName":"Broken"},
          {"npCommunicationId":"NPWR00004_00","trophyTitleName":"  "}
        ],"totalItemCount":5}
        """#.utf8)
        let titles = TrophyTitle.list(data)
        XCTAssertEqual(titles.map(\.name), ["Newer Game", "Older Game", "No Icon"], "Latest first; a list without a date at the end; broken rows left out")
        XCTAssertEqual(titles[0].id, "NPWR00002_00")
        XCTAssertEqual(titles[0].platform, "PS5")
        XCTAssertEqual(titles[0].progress, 100)
        XCTAssertEqual(titles[0].earned.platinum, 1)
        XCTAssertEqual(titles[0].defined.total, 51)
        XCTAssertEqual(titles[0].iconURL?.host, "image.api.playstation.com")
        XCTAssertNotNil(titles[0].updated)
        XCTAssertEqual(titles[1].earned, TrophyCounts(bronze: 5))
        XCTAssertNil(titles[2].iconURL, "Only pictures over TLS")
        XCTAssertEqual(titles[2].progress, 7)
        XCTAssertEqual(TrophyTitle.list(Data(#"{"error":{}}"#.utf8)), [])
    }

    func testTrophiesAreKeptAsTheyWere() throws {
        let kept = AccountTrophies(summary: TrophySummary(level: 12, progress: 50, tier: 1, earned: TrophyCounts(gold: 1, bronze: 9)),
                                   titles: [TrophyTitle(id: "NPWR1", name: "Game", platform: "PS5", iconURL: URL(string: "https://example.com/i.png"),
                                                        progress: 10, earned: TrophyCounts(bronze: 1), defined: TrophyCounts(bronze: 10), updated: Date(timeIntervalSince1970: 1_700_000_000))])
        XCTAssertEqual(try JSONDecoder().decode(AccountTrophies.self, from: JSONEncoder().encode(kept)), kept)
    }

    func testPSNTimesAreReadWithAndWithoutFractions() {
        XCTAssertEqual(PSNTime.date("2026-10-12T18:04:31Z")?.timeIntervalSince1970, 1_791_828_271)
        XCTAssertEqual(PSNTime.date("2026-10-12T18:04:31.520Z")?.timeIntervalSince1970 ?? 0, 1_791_828_271.52, accuracy: 0.001)
        XCTAssertNil(PSNTime.date("yesterday"))
        XCTAssertNil(PSNTime.date(nil))
    }

    func testTheHistoryTellsWhenAGameWasLastPlayed() throws {
        let data = Data(#"{"titles":[{"titleId":"PPSA00001_00","name":"Game","category":"ps5_native_game","playCount":3,"playDuration":"PT2H5M","firstPlayedDateTime":"2026-01-02T03:04:05Z","lastPlayedDateTime":"2026-10-12T18:04:31.52Z"},{"titleId":"CUSA00001_00","name":"Old"}]}"#.utf8)
        let page = try JSONDecoder().decode(PlayedGamesPage.self, from: data)
        XCTAssertEqual(page.titles[0].lastPlayed?.timeIntervalSince1970 ?? 0, 1_791_828_271.52, accuracy: 0.001)
        XCTAssertNil(page.titles[1].lastPlayed)
    }
}
