import XCTest
import SoleCloud
import SoleCore
@testable import SoleLogic

final class AccountPageTests: XCTestCase {
    private actor MemoryStore: CredentialStore {
        func read(_ account: String) async throws -> Data? { nil }
        func write(_ data: Data, account: String) async throws {}
        func remove(_ account: String) async throws {}
    }
    @MainActor private final class Page: SonyLoginPage {
        func signIn(url: URL, state: String) async throws -> SonyLogin { throw PSNAuthorization.AuthError.cancelled }
        func cancel() {}
    }
    @MainActor private final class Player: StreamPlayer {
        var accountProvider: (() async throws -> [UInt8])?
        var cloudEnded: ((String?) -> Void)?
        var cloudRestart: (() -> Void)?
        var vibration = true, fillsWindow = false, hasControls = false
        func connectCloud(_ stream: CloudStream) {}
        func disconnect() {}
        func startDiscovery() {}
        func stopDiscovery() {}
    }
    @MainActor private func model(_ defaults: UserDefaults) -> AppModel {
        AppModel(store: MemoryStore(), website: Page(), player: Player(), defaults: defaults, caches: nil)
    }
    private var account: Account { Account(PSNProfile.decode(Data(#"{"onlineId":"tester"}"#.utf8))!) }
    private let sample = AccountTrophies(
        summary: TrophySummary(level: 432, progress: 33, tier: 5, earned: TrophyCounts(platinum: 47, gold: 165, silver: 557, bronze: 2234)),
        titles: (1...6).map { TrophyTitle(id: "NPWR0000\($0)_00", name: "Game \($0)", platform: $0 == 1 ? "PS5,PSPC" : "PS4", iconURL: nil, progress: 10 * $0,
                                          earned: TrophyCounts(bronze: $0), defined: TrophyCounts(gold: 1, bronze: 20), updated: nil) })

    private func history(_ json: String) throws -> [PlayedTitle] { try JSONDecoder().decode(PlayedGamesPage.self, from: Data(json.utf8)).titles }

    func testTheGamesPlayedLastComeFirstEachOnceAndNoMoreThanTen() throws {
        var rows = [#"{"titleId":"CUSA00001_00","name":"Old","lastPlayedDateTime":"2024-01-01T00:00:00Z"}"#,
                    #"{"titleId":"PPSA00002_00","name":"Newest","concept":{"id":7},"category":"ps5_native_game","lastPlayedDateTime":"2026-10-12T18:00:00Z"}"#,
                    #"{"titleId":"CUSA00002_00","name":"Newest (PS4)","concept":{"id":7},"lastPlayedDateTime":"2026-09-01T18:00:00Z"}"#,
                    #"{"titleId":"CUSA00003_00","name":"Never dated"}"#]
        rows += (10..<20).map { #"{"titleId":"CUSA000\#($0)_00","name":"Game \#($0)","lastPlayedDateTime":"2025-05-\#($0)T00:00:00Z"}"# }
        let recent = AccountPage.recent(try history(#"{"titles":[\#(rows.joined(separator: ","))]}"#), favorites: ["concept:7"])
        XCTAssertEqual(recent.count, 10)
        XCTAssertEqual(recent.first?.game.title, "Newest", "A concept is listed once, by its latest play")
        XCTAssertEqual(recent.first?.game.id, "concept:7")
        XCTAssertTrue(recent.first?.game.favorite == true)
        XCTAssertEqual(recent.first?.lastPlayed, PSNTime.date("2026-10-12T18:00:00Z"))
        XCTAssertEqual(recent[1].game.title, "Game 19")
        XCTAssertFalse(recent.contains { $0.game.title == "Never dated" || $0.game.title == "Old" }, "Older and undated games are past the tenth")
        let few = AccountPage.recent(try history(#"{"titles":[{"titleId":"A","name":"Undated"},{"titleId":"B","name":"Dated","lastPlayedDateTime":"2026-01-01T00:00:00Z"}]}"#), favorites: [])
        XCTAssertEqual(few.map(\.game.title), ["Dated", "Undated"])
        XCTAssertNil(few[1].lastPlayed)
    }

    func testLastPlayedIsShownAsRelativeText() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = PSNTime.date("2026-10-16T12:00:00Z")!
        func text(_ date: String) -> String? { AccountPage.lastPlayedText(PSNTime.date(date), now: now, calendar: calendar) }
        XCTAssertEqual(text("2026-10-16T00:30:00Z"), "Today")
        XCTAssertEqual(text("2026-10-15T23:59:00Z"), "Yesterday")
        XCTAssertEqual(text("2026-10-10T08:00:00Z"), "6 days ago")
        XCTAssertEqual(text("2026-08-03T08:00:00Z"), "03.08.2026")
        XCTAssertEqual(text("2026-10-17T08:00:00Z"), "Today", "A clock a little ahead is not the future")
        XCTAssertNil(AccountPage.lastPlayedText(nil, now: now))
    }

    @MainActor func testTheTrophiesAreReadKeptAndShownByGrade() async throws {
        let defaults = testSettings()
        let model = model(defaults)
        XCTAssertFalse(AccountPage(model).shown, "Without an account there is no page under the sign-in")
        model.reloadTrophies()
        XCTAssertFalse(model.loadingTrophies, "Nothing is asked without an account")
        model.account = account
        var asked = 0
        model.fetchTrophies = { [sample] in asked += 1; return .init(summaryStatus: 200, titlesStatus: 200, trophies: sample) }
        model.reloadTrophies()
        XCTAssertTrue(model.loadingTrophies)
        XCTAssertEqual(AccountPage(model).trophyNote, "Loading trophies…")
        model.reloadTrophies()
        while model.loadingTrophies { await Task.yield() }
        XCTAssertEqual(asked, 1, "One reading at a time")
        let page = AccountPage(model)
        XCTAssertTrue(page.shown)
        XCTAssertNil(page.trophyNote)
        XCTAssertEqual(page.levelText, "Level 432")
        XCTAssertEqual(page.progressText, "33% to level 433")
        XCTAssertEqual(page.grades.map(\.count), [47, 165, 557, 2234])
        XCTAssertEqual(page.grades.map(\.grade.title), ["Platinum", "Gold", "Silver", "Bronze"])
        XCTAssertEqual(page.trophyTitles.map(\.name), ["Game 1", "Game 2", "Game 3", "Game 4"], "A handful of lists")
        XCTAssertEqual(AccountPage.trophyTitleNote(page.trophyTitles[0]), "PS5 · PSPC · 1 of 21")
        XCTAssertEqual(self.model(defaults).trophies, sample)
    }

    @MainActor func testARefusedTokenShowsANoteAndAFailureKeepsTheLastTrophies() async throws {
        let model = model(testSettings())
        model.account = account
        model.fetchTrophies = { .init(summaryStatus: 403, titlesStatus: nil, trophies: nil) }
        model.reloadTrophies()
        while model.loadingTrophies { await Task.yield() }
        XCTAssertEqual(model.trophiesFailure, .refused)
        XCTAssertEqual(AccountPage(model).trophyNote, "Sony does not show trophies for this sign-in.")
        model.fetchTrophies = { [sample] in .init(summaryStatus: 200, titlesStatus: 500, trophies: AccountTrophies(summary: sample.summary, titles: [])) }
        model.reloadTrophies()
        while model.loadingTrophies { await Task.yield() }
        XCTAssertNil(model.trophiesFailure)
        XCTAssertEqual(AccountPage(model).levelText, "Level 432", "Without the lists the summary is still shown")
        XCTAssertEqual(AccountPage(model).trophyTitles.count, 0)
        model.fetchTrophies = { throw URLError(.notConnectedToInternet) }
        model.reloadTrophies()
        while model.loadingTrophies { await Task.yield() }
        XCTAssertEqual(model.trophiesFailure, .failed)
        XCTAssertNil(AccountPage(model).trophyNote)
        XCTAssertNotNil(model.trophies)
    }

    func testOnlyTheStatusesAreWrittenDown() {
        let record = AccountPage.diagnostics(summaryStatus: 403, titlesStatus: nil, read: false)
        XCTAssertEqual(record as NSDictionary, ["trophySummary": 403, "read": false] as NSDictionary)
        XCTAssertEqual(AccountPage.diagnostics(summaryStatus: 200, titlesStatus: 200, read: true) as NSDictionary,
                       ["trophySummary": 200, "trophyTitles": 200, "read": true] as NSDictionary)
    }

    @MainActor func testTheRecentGamesSayWhyThereAreNone() {
        let model = model(testSettings())
        model.account = account
        XCTAssertEqual(AccountPage(model).recentNote, "No recent games yet.")
        model.loadingLibrary = true
        XCTAssertEqual(AccountPage(model).recentNote, "Loading recent games…")
        model.loadingLibrary = false; model.libraryError = "x"
        XCTAssertEqual(AccountPage(model).recentNote, "Could not load recent games. Try refreshing the library.")
    }

    @MainActor func testTheAccountTabTitle() {
        XCTAssertEqual(loc(SettingsSection.account.rawValue), "PSN Account")
    }

    @MainActor func testRecentTargetID() {
        XCTAssertEqual(LibraryScreen.Target.recent("concept:7"), "recent:concept:7")
    }
}
