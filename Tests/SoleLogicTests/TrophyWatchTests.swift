import XCTest
import SoleCloud
@testable import SoleCore
@testable import SoleLogic

final class TrophyWatchTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_792_300_000)
    private static func title(_ id: String, earned bronze: Int, updated: Date? = nil, platform: String = "PS5") -> TrophyTitle {
        TrophyTitle(id: id, name: "Game \(id)", platform: platform, iconURL: nil, progress: 0, earned: TrophyCounts(bronze: bronze), defined: TrophyCounts(bronze: 40), updated: updated)
    }
    @MainActor private func makeModel(player: Player, defaults: UserDefaults? = nil) -> AppModel {
        AppModel(store: MemoryStore(), website: Page(), player: player, defaults: defaults ?? testSettings(), caches: nil)
    }

    func testSonysListsOfTrophiesAreRead() {
        let defined = TrophyDefinition.list(Data(#"{"trophies":[{"trophyId":7,"trophyHidden":false,"trophyType":"gold","trophyName":" Ace ","trophyDetail":"Win","trophyIconUrl":"https://image.api.playstation.com/t/7.png"},{"trophyName":"no id"}]}"#.utf8))
        XCTAssertEqual(defined, [TrophyDefinition(id: 7, name: "Ace", detail: "Win", grade: "gold", iconURL: URL(string: "https://image.api.playstation.com/t/7.png"))])
        let earned = EarnedTrophy.list(Data(#"{"trophies":[{"trophyId":7,"earned":true,"earnedDateTime":"2026-10-18T12:00:00Z"},{"trophyId":8,"earned":false}]}"#.utf8))
        XCTAssertEqual(earned.map(\.id), [7, 8]); XCTAssertTrue(earned[0].earned); XCTAssertNotNil(earned[0].date); XCTAssertNil(earned[1].date)
        let titles = TrophyTitle.list(Data(#"{"trophyTitles":[{"npCommunicationId":"NPWR1_00","trophyTitleName":"A","trophyTitlePlatform":"PS4","npServiceName":"trophy"},{"npCommunicationId":"NPWR2_00","trophyTitleName":"B","trophyTitlePlatform":"PS5"}]}"#.utf8))
        XCTAssertEqual(titles.map(\.serviceName), ["trophy", "trophy2"])
        XCTAssertEqual(PSNAuthorization.trophyListID("NPWR1_00"), "NPWR1_00"); XCTAssertNil(PSNAuthorization.trophyListID("NPWR/../x"))
    }

    func testOnlyTrophiesEarnedSinceTheStreamBeganAreShownOnce() {
        var watch = TrophyWatch(since: start)
        XCTAssertEqual(watch.grown([Self.title("A", earned: 3), Self.title("B", earned: 10)]), [], "The first reading sets the baseline")
        XCTAssertEqual(watch.grown([Self.title("A", earned: 3), Self.title("B", earned: 10)]), [])
        let grown = watch.grown([Self.title("A", earned: 4), Self.title("B", earned: 10)])
        XCTAssertEqual(grown.map(\.id), ["A"])
        let earned = [EarnedTrophy(id: 1, earned: true, date: start.addingTimeInterval(-3600)), EarnedTrophy(id: 5, earned: true, date: start.addingTimeInterval(90)),
                      EarnedTrophy(id: 2, earned: true, date: start.addingTimeInterval(40)), EarnedTrophy(id: 9, earned: false, date: nil)]
        let defined = [TrophyDefinition(id: 5, name: "Five", detail: "", grade: "silver", iconURL: nil), TrophyDefinition(id: 2, name: "Two", detail: "", grade: "gold", iconURL: nil)]
        let notices = watch.notices(grown[0], earned: earned, defined: defined)
        XCTAssertEqual(notices.map(\.name), ["Two", "Five"], "Earned since the start, earliest first")
        XCTAssertEqual(notices.first?.grade, "gold"); XCTAssertEqual(notices.first?.game, "Game A")
        XCTAssertEqual(watch.notices(grown[0], earned: earned, defined: defined), [], "Not shown twice")
    }

    func testAGamesFirstTrophyAppearsAsANewList() {
        var watch = TrophyWatch(since: start)
        _ = watch.grown([Self.title("A", earned: 3)])
        let grown = watch.grown([Self.title("N", earned: 1, updated: start.addingTimeInterval(30)), Self.title("O", earned: 5, updated: start.addingTimeInterval(-86400)), Self.title("A", earned: 3)])
        XCTAssertEqual(grown.map(\.id), ["N"], "A list last updated before the stream is not new")
    }

    @MainActor func testTheModelShowsWhatWasEarnedWhileTheGameStreams() async {
        let player = Player()
        let model = makeModel(player: player)
        model.trophyInterval = 20_000_000
        var count = 0
        model.trophySource = .init(
            titles: { count += 1; return (200, [Self.title("A", earned: count > 2 ? 2 : 1)]) },
            earned: { _ in (200, [EarnedTrophy(id: 3, earned: true, date: Date())]) },
            defined: { _ in (200, [TrophyDefinition(id: 3, name: "Three", detail: "", grade: "bronze", iconURL: nil)]) })
        model.watchTrophies()
        for _ in 0..<100 where player.trophies.isEmpty { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(player.trophies.map(\.name), ["Three"])
        player.cloudEnded?(nil)
        let seen = count
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertLessThanOrEqual(count, seen + 1, "Watching stops when the stream ends")
    }

    @MainActor func testATrophyWhoseListDidNotComeIsAskedForAgain() async {
        let player = Player()
        let model = makeModel(player: player)
        model.trophyInterval = 20_000_000
        var count = 0, asked = 0
        model.trophySource = .init(
            titles: { count += 1; return (200, [Self.title("A", earned: count > 1 ? 2 : 1)]) },
            earned: { _ in
                asked += 1
                if asked == 1 { return (500, []) }
                return (200, [EarnedTrophy(id: 3, earned: true, date: Date())])
            },
            defined: { _ in (200, [TrophyDefinition(id: 3, name: "Three", detail: "", grade: "bronze", iconURL: nil)]) })
        model.watchTrophies()
        for _ in 0..<100 where player.trophies.isEmpty { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(player.trophies.map(\.name), ["Three"], "Sony's list failed once: the trophy is still shown")
        let shownAfter = asked
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(asked, shownAfter, "Once shown, its list is not requested again")
        player.cloudEnded?(nil)
    }

    @MainActor func testAStreamThatEndedAsItBeganIsNotWatchedForTrophies() async throws {
        let player = Player()
        let model = makeModel(player: player)
        model.trophyInterval = 10_000_000
        var asked = 0
        model.trophySource = .init(titles: { asked += 1; return (200, []) }, earned: { _ in (200, []) }, defined: { _ in (200, []) })
        let prepared = try preparation()
        model.prepareCloud = { _, _, _ in prepared }
        model.account = Account(PSNProfile.decode(Data(#"{"onlineId":"tester","isPlus":true}"#.utf8))!)
        model.connectCloud()
        for _ in 0..<200 where model.connectingCloud { try? await Task.sleep(nanoseconds: 5_000_000) }
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(asked, 0, "The stream failed immediately: nothing is requested from Sony")
        player.live = true
        model.connectCloud()
        for _ in 0..<200 where asked == 0 { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertGreaterThan(asked, 0, "A running stream is watched")
        player.cloudEnded?(nil)
    }

    private func preparation() throws -> CloudAuthorization.Preparation {
        let centers = try CloudDatacenter.decode(Data(#"[{"dataCenter":"fraa","publicIp":"192.0.2.10","port":2053}]"#.utf8))
        let slot = #"{"launchSlot":{"publicIp":"192.0.2.20","port":2054},"handshakeKey":"AAECAwQFBgcICQoLDA0ODw==","sessionId":"session-1","launchSpecification":"spec"}"#
        guard case .ready(let launch) = try CloudAllocation.decode(Data(slot.utf8)) else { throw CloudAllocation.Failure.invalidSlot }
        return .init(centers: centers, latencies: [:], selected: centers[0], reportedLatency: nil, mtuIn: 1400, mtuOut: 1200, slot: launch)
    }

    @MainActor func testTheNoticesAreOnUnlessTurnedOffAndOffNothingIsAskedOfSony() async {
        let defaults = testSettings()
        let model = makeModel(player: Player(), defaults: defaults)
        XCTAssertTrue(model.trophyNotices, "On by default")
        model.trophyInterval = 10_000_000
        var asked = 0
        model.trophySource = .init(titles: { asked += 1; return (200, []) }, earned: { _ in (200, []) }, defined: { _ in (200, []) })
        model.trophyNotices = false
        XCTAssertEqual(defaults.object(forKey: "sole.trophyNotices") as? Bool, false)
        model.watchTrophies()
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(asked, 0)
        let again = makeModel(player: Player(), defaults: defaults)
        XCTAssertFalse(again.trophyNotices, "The setting persists")
    }

    @MainActor private final class Player: StreamPlayer {
        var accountProvider: (() async throws -> [UInt8])?
        var cloudEnded: ((String?) -> Void)?
        var cloudRestart: (() -> Void)?
        var vibration = true, fillsWindow = false, hasControls = false, live = false
        var trophies: [TrophyNotice] = []
        func connectCloud(_ stream: CloudStream) {
            hasControls = live
            if !live { cloudEnded?("refused") }
        }
        func disconnect() {}
        func startDiscovery() {}
        func stopDiscovery() {}
        func showTrophy(_ notice: TrophyNotice) { trophies.append(notice) }
    }
    private actor MemoryStore: CredentialStore {
        func read(_ account: String) async throws -> Data? { nil }
        func write(_ data: Data, account: String) async throws {}
        func remove(_ account: String) async throws {}
    }
    @MainActor private final class Page: SonyLoginPage {
        func signIn(url: URL, state: String) async throws -> SonyLogin { throw PSNAuthorization.AuthError.cancelled }
        func cancel() {}
    }
}
