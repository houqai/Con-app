import XCTest
import SoleCloud
import SoleCore
import SoleEngine
@testable import SoleLogic

final class LibraryScreenTests: XCTestCase {
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
    @MainActor private struct Screen {
        let model: AppModel, focus: FocusModel, screen: LibraryScreen, player: Player
        var chosen: String? { model.selectedGame?.id }
    }
    @MainActor private func screen(games count: Int = 40, columns: Int = 4) -> Screen {
        let player = Player()
        let model = AppModel(store: MemoryStore(), website: Page(), player: player, defaults: testSettings(), caches: nil)
        model.catalogGames = (0..<count).map { Game(id: "g\($0)", title: String(format: "Game %03d", $0), platform: "PS5", favorite: false, artworkURL: nil) }
        let focus = FocusModel()
        let screen = LibraryScreen(model: model, focus: focus)
        screen.columns = columns
        return Screen(model: model, focus: focus, screen: screen, player: player)
    }

    @MainActor func testTheCatalogIsShownThreeRowsAtATime() async {
        let library = screen(games: 40, columns: 4)
        XCTAssertEqual(library.screen.games.count, 40)
        XCTAssertEqual(library.screen.visibleCount, 12); XCTAssertTrue(library.screen.hasMore)
        library.screen.showMore()
        XCTAssertEqual(library.screen.visibleCount, 24)
        XCTAssertNil(library.chosen, "Showing more rows selects nothing")
        library.screen.startOver()
        XCTAssertEqual(library.screen.visibleCount, 12)
        let few = screen(games: 5, columns: 4)
        XCTAssertFalse(few.screen.hasMore)
    }

    @MainActor func testTheFirstPressChoosesTheFirstGame() async {
        let library = screen()
        let games = library.screen.games
        XCTAssertEqual(library.screen.game?.id, games[0].id, "Before any is chosen the first one stands in")
        library.screen.handle(.right)
        XCTAssertEqual(library.chosen, games[0].id, "The first move takes the first game, not its neighbor")
        XCTAssertEqual(library.focus.selected, LibraryScreen.Target.game(games[0].id))
    }

    @MainActor func testPressesMoveTheChoiceInTheOrderOfTheCatalog() async {
        let library = screen(games: 40, columns: 4)
        let games = library.screen.games
        library.screen.handle(.right); library.screen.handle(.right)
        XCTAssertEqual(library.chosen, games[1].id)
        library.screen.handle(.down)
        XCTAssertEqual(library.chosen, games[5].id, "Down is a row further")
        library.screen.handle(.left); library.screen.handle(.left); library.screen.handle(.left)
        XCTAssertEqual(library.chosen, games[2].id, "Left goes on into the row above")
        library.screen.handle(.up)
        XCTAssertEqual(library.focus.selected, LibraryScreen.Target.filter(library.model.filter), "Up from the first row leads to the filters")
        XCTAssertEqual(library.chosen, games[2].id, "The game stays chosen while the frame is elsewhere")
    }

    @MainActor func testBelowTheLastShownRowIsTheButtonForMore() async {
        let library = screen(games: 40, columns: 4)
        let games = library.screen.games
        library.screen.handle(.right)
        library.screen.handle(.down); library.screen.handle(.down)
        XCTAssertEqual(library.chosen, games[8].id)
        library.screen.handle(.down)
        XCTAssertEqual(library.focus.selected, LibraryScreen.Target.more)
        XCTAssertEqual(library.chosen, games[8].id)
        library.screen.showMore()
        XCTAssertEqual(library.chosen, games[12].id)
        XCTAssertEqual(library.focus.selected, LibraryScreen.Target.game(games[12].id))
        let few = screen(games: 6, columns: 4)
        few.screen.handle(.right); few.screen.handle(.down); few.screen.handle(.down)
        XCTAssertEqual(few.chosen, few.screen.games[5].id)
    }

    @MainActor func testAChoiceThatIsNotShownAnyMoreMovesToTheLastShown() async {
        let library = screen(games: 40, columns: 6)
        let games = library.screen.games
        library.screen.handle(.right)
        library.screen.handle(.down); library.screen.handle(.down)
        for _ in 0..<5 { library.screen.handle(.right) }
        XCTAssertEqual(library.chosen, games[17].id)
        library.screen.columns = 3
        XCTAssertEqual(library.chosen, games[8].id)
        XCTAssertEqual(library.focus.selected, LibraryScreen.Target.game(games[8].id))
    }

    @MainActor func testPlayOpensTheGamesPageAndBackClosesWhatIsOpen() async {
        let library = screen()
        library.screen.handle(.right)
        library.screen.handle(.play)
        XCTAssertTrue(library.model.gameOpen); XCTAssertTrue(library.screen.gamePageOpen)
        library.screen.gamePageChanged(open: true)
        XCTAssertEqual(library.focus.selected, LibraryScreen.Target.pagePlay)
        library.screen.handle(.settings)
        XCTAssertTrue(library.model.settingsOpen)
        library.screen.handle(.back)
        XCTAssertFalse(library.model.settingsOpen); XCTAssertTrue(library.model.gameOpen, "Back closes one thing at a time")
        library.screen.handle(.back)
        XCTAssertFalse(library.model.gameOpen)
        library.screen.gamePageChanged(open: false)
        XCTAssertEqual(library.focus.selected, LibraryScreen.Target.game(library.screen.games[0].id), "The frame returns to the game")
    }

    @MainActor func testWithoutAnAccountPlayOpensTheSignIn() async {
        let library = screen()
        library.screen.play(library.screen.games[0])
        XCTAssertTrue(library.model.loginOpen); XCTAssertFalse(library.screen.launching)
        library.screen.handle(.right)
        XCTAssertNil(library.chosen)
        XCTAssertFalse(library.screen.key(Key.right, text: ""))
    }

    @MainActor func testTheLaunchCoversTheScreenUntilItIsCancelled() async {
        let library = screen()
        var changes = 0
        library.screen.willChange = { changes += 1 }
        library.focus.update([FocusTarget(id: LibraryScreen.Target.launchCancel, at: (0, 0), activate: {})])
        library.screen.launching = true
        XCTAssertEqual(changes, 1)
        library.screen.handle(.right)
        XCTAssertEqual(library.focus.selected, LibraryScreen.Target.launchCancel, "During a launch only Cancel can take focus")
        XCTAssertNil(library.chosen)
        library.screen.handle(.back)
        XCTAssertFalse(library.screen.launching)
        library.screen.launching = true
        XCTAssertTrue(library.screen.key(Key.escape, text: ""))
        XCTAssertFalse(library.screen.launching)
    }

    @MainActor func testOverALaunchTheGamepadHasTheWayOutOnly() async {
        let library = screen()
        library.model.account = Account(PSNProfile.decode(Data(#"{"onlineId":"tester","isPlus":true}"#.utf8))!)
        library.model.prepareCloud = { _, _, _ in throw CloudProtocol.Failure.service(500, "Preparing the game session") }
        var cancelled = 0
        library.focus.update([FocusTarget(id: LibraryScreen.Target.launchCancel, at: (0, 0), activate: { cancelled += 1 })])
        let wanted = Game(id: "busy", title: "Busy", platform: "PS5", favorite: false, artworkURL: nil, productID: "UP0001-PPSA00001_00-GAME000000000000")
        library.screen.play(wanted)
        for _ in 0..<200 where library.model.connectingCloud { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(library.screen.launching)
        library.screen.handle(.left)
        XCTAssertEqual(library.focus.selected, LibraryScreen.Target.launchCancel)
        library.screen.handle(.play)
        XCTAssertEqual(cancelled, 1)
        library.focus.update([])
        library.screen.play(wanted)
        for _ in 0..<200 where library.model.connectingCloud { try? await Task.sleep(nanoseconds: 5_000_000) }
        library.screen.handle(.play)
        XCTAssertFalse(library.screen.launching)
    }

    @MainActor func testAStreamHasTheGamepadAndTheKeys() async {
        let library = screen()
        library.player.hasControls = true
        library.screen.handle(.right)
        XCTAssertNil(library.chosen)
        XCTAssertFalse(library.screen.key(Key.right, text: ""))
        library.player.hasControls = false
        library.screen.handle(.right)
        XCTAssertNotNil(library.chosen)
    }

    @MainActor func testTheKeysOfTheKeyboardInTheLibrary() async {
        let library = screen(games: 40, columns: 4)
        let games = library.screen.games
        XCTAssertTrue(library.screen.key(Key.right, text: ""))
        XCTAssertEqual(library.chosen, games[0].id)
        XCTAssertTrue(library.screen.key(Key.down, text: ""))
        XCTAssertEqual(library.chosen, games[4].id)
        XCTAssertTrue(library.screen.key(Key.f, text: "f"))
        XCTAssertTrue(library.model.orderedGames.first(where: { $0.id == games[4].id })?.favorite == true, "F marks the chosen game")
        XCTAssertTrue(library.screen.key(Key.f, text: "А"), "The same key while Russian is typed")
        XCTAssertFalse(library.screen.key(Key.q, text: "q"), "Other keys are left to the app")
        XCTAssertFalse(library.screen.key(nil, text: ""))
        XCTAssertTrue(library.screen.key(Key.enter, text: "\r"))
        XCTAssertTrue(library.model.gameOpen)
        XCTAssertTrue(library.screen.key(Key.escape, text: ""))
        XCTAssertFalse(library.model.gameOpen)
        library.model.showSettings()
        XCTAssertTrue(library.screen.key(Key.escape, text: ""))
        XCTAssertFalse(library.model.settingsOpen)
    }

    @MainActor func testAPressFromTheGamepadIsDistinguishedFromAKey() async {
        let library = screen()
        var seen: [Bool] = []
        library.focus.update([FocusTarget(id: LibraryScreen.Target.search, at: (0, 0), activate: { seen.append(library.screen.fromGamepad) })])
        library.model.settingsOpen = false
        library.focus.selected = LibraryScreen.Target.search
        library.screen.gamepad(.play)
        library.screen.handle(.play)
        XCTAssertEqual(seen, [true, false])
        XCTAssertFalse(library.screen.fromGamepad)
    }

    @MainActor func testTypingASearchWithTheGamepadChoosesWhatItFound() async {
        let library = screen()
        library.screen.typeSearch()
        XCTAssertNotNil(library.focus.keyboard)
        library.focus.closeKeyboard(done: true)
        XCTAssertEqual(library.chosen, library.screen.games[0].id)
        XCTAssertEqual(library.focus.selected, LibraryScreen.Target.game(library.screen.games[0].id))
    }

    @MainActor func testAnotherCatalogStartsWithNothingChosen() async {
        let library = screen()
        library.screen.handle(.right); library.screen.showMore()
        XCTAssertNotNil(library.chosen)
        library.screen.catalogReplaced()
        XCTAssertNil(library.chosen); XCTAssertEqual(library.screen.visibleRows, LibraryScreen.rowsStep)
    }

    @MainActor func testAnEmptyLibrarySaysWhy() async {
        let library = screen(games: 0)
        XCTAssertEqual(library.screen.emptyText, "No games found")
        library.model.filter = .owned
        XCTAssertEqual(library.screen.emptyText, "Sign in to PlayStation to see your purchased games.")
        library.model.search = "zzz"
        XCTAssertEqual(library.screen.emptyText, "No games found")
    }
}
