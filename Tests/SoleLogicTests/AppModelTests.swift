import XCTest
import SoleCloud
import SoleCore
@testable import SoleLogic

final class AppModelTests: XCTestCase {
    private actor MemoryStore: CredentialStore {
        var records: [String: Data] = [:]
        func read(_ account: String) async throws -> Data? { records[account] }
        func write(_ data: Data, account: String) async throws { records[account] = data }
        func remove(_ account: String) async throws { records[account] = nil }
        func put(_ data: Data, _ account: String) { records[account] = data }
    }
    @MainActor private final class Page: SonyLoginPage {
        var opened = 0, cancelled = 0
        func signIn(url: URL, state: String) async throws -> SonyLogin { opened += 1; throw PSNAuthorization.AuthError.cancelled }
        func cancel() { cancelled += 1 }
    }
    @MainActor private final class Player: StreamPlayer {
        var accountProvider: (() async throws -> [UInt8])?
        var cloudEnded: ((String?) -> Void)?
        var cloudRestart: (() -> Void)?
        var calls: [String] = []
        var vibration = true, fillsWindow = false
        var hasControls = false
        func connectCloud(_ stream: CloudStream) { calls.append("connect " + stream.title) }
        func disconnect() { calls.append("disconnect") }
        func startDiscovery() { calls.append("startDiscovery") }
        func stopDiscovery() { calls.append("stopDiscovery") }
    }
    @MainActor private func model(_ defaults: UserDefaults, store: MemoryStore = MemoryStore(), page: Page? = nil, player: Player? = nil) -> AppModel {
        AppModel(store: store, website: page ?? Page(), player: player ?? Player(), defaults: defaults, caches: nil)
    }
    private func game(_ id: String, _ title: String, _ backend: CloudBackend = .ps5, favorite: Bool = false, concept: Int? = nil, product: String? = nil) -> Game {
        Game(id: id, title: title, platform: backend.console, favorite: favorite, artworkURL: nil, conceptID: concept, productID: product, cloudBackend: backend)
    }
    private var profile: PSNProfile { PSNProfile.decode(Data(#"{"onlineId":"tester","isPlus":true}"#.utf8))! }

    @MainActor func testANewInstallationStartsFromTheDefaults() async {
        let defaults = testSettings()
        let model = model(defaults)
        XCTAssertEqual(model.resolution, 1080); XCTAssertEqual(model.bitrate, 30); XCTAssertTrue(model.haptics)
        XCTAssertEqual(model.language, "en")
        XCTAssertEqual(model.gameLanguage, "en", "The game is asked for in English unless another language is chosen")
        XCTAssertEqual(model.catalogLocale, "en-us")
        XCTAssertTrue(model.touchGamepad)
        XCTAssertEqual(model.videoFit, "fit"); XCTAssertEqual(model.selectedDatacenter, "auto")
        XCTAssertEqual(model.filter, .all); XCTAssertEqual(model.catalogBackend, .ps5); XCTAssertEqual(model.destination, .cloud)
        XCTAssertTrue(model.owned.isEmpty); XCTAssertTrue(model.datacenters.isEmpty); XCTAssertNil(model.account)
        XCTAssertNil(defaults.object(forKey: "sole.resolution"), "Reading the settings writes nothing")
        XCTAssertNil(defaults.object(forKey: "sole.datacenter"))
    }

    @MainActor func testDistantServersAreOffUntilTurnedOnAndTheChoiceIsKept() async {
        let defaults = testSettings()
        let first = model(defaults)
        XCTAssertFalse(first.distantServers, "Sony's latency limit is kept unless the player chooses otherwise")
        first.distantServers = true
        XCTAssertEqual(defaults.object(forKey: "sole.distantServers") as? Bool, true)
        XCTAssertTrue(model(defaults).distantServers)
    }

    @MainActor func testSettingsAreReadAsTheyWereSavedAndAsTheCommandLineGivesThem() async throws {
        let saved = try JSONEncoder().encode([Datacenter(id: "fraa", latency: 40)])
        let model = model(testSettings(["sole.resolution": "540", "sole.bitrate": "8.5", "sole.haptics": "NO", "sole.language": "ru", "sole.gameLanguage": "en", "sole.catalogLocale": "de-de",
                                    "sole.libraryFilter": "Recent", "con.catalogBackend": "psPlusPC", "sole.datacenters": saved, "sole.datacenter": "fraa"]))
        XCTAssertEqual(model.resolution, 540, "A value of one run comes as a text")
        XCTAssertEqual(model.bitrate, 8.5); XCTAssertFalse(model.haptics)
        XCTAssertEqual(model.language, "ru"); XCTAssertEqual(model.gameLanguage, "en"); XCTAssertEqual(model.catalogLocale, "de-de")
        XCTAssertEqual(model.filter, .recent); XCTAssertEqual(model.catalogBackend, .psPlusPC)
        XCTAssertEqual(model.datacenters.map(\.id), ["fraa"]); XCTAssertEqual(model.selectedDatacenter, "fraa")
    }

    @MainActor func testAChosenServerThatIsNotKnownAnyMoreIsNoChoice() async {
        let defaults = testSettings(["sole.datacenter": "gone"])
        XCTAssertEqual(model(defaults).selectedDatacenter, "auto")
        XCTAssertEqual(defaults.string(forKey: "sole.datacenter"), "auto")
    }

    @MainActor func testEveryChangeOfASettingIsKept() async throws {
        let defaults = testSettings()
        let model = model(defaults)
        model.selectPreset(1440)
        XCTAssertEqual(defaults.integer(forKey: "sole.resolution"), 1440); XCTAssertEqual(defaults.double(forKey: "sole.bitrate"), 40)
        model.bitrate = 22; model.haptics = false; model.language = "ru"; model.gameLanguage = "ja"; model.catalogLocale = "ja-jp"; model.videoFit = "fill"
        model.catalogBackend = .ps3; model.filter = .favorites; model.selectedDatacenter = "tyob"
        model.datacenters = [Datacenter(id: "tyob", latency: 104)]
        XCTAssertEqual(defaults.double(forKey: "sole.bitrate"), 22); XCTAssertEqual(defaults.object(forKey: "sole.haptics") as? Bool, false)
        XCTAssertEqual(defaults.string(forKey: AppLanguage.storageKey), "ru"); XCTAssertEqual(defaults.string(forKey: "sole.gameLanguage"), "ja")
        model.touchGamepad = false
        XCTAssertEqual(defaults.object(forKey: "sole.touchGamepad") as? Bool, false)
        XCTAssertEqual(defaults.string(forKey: "sole.catalogLocale"), "ja-jp"); XCTAssertEqual(defaults.string(forKey: "sole.videoFit"), "fill")
        XCTAssertEqual(defaults.string(forKey: "con.catalogBackend"), "ps3"); XCTAssertEqual(defaults.string(forKey: "sole.libraryFilter"), "Favorites")
        XCTAssertEqual(defaults.string(forKey: "sole.datacenter"), "tyob")
        XCTAssertEqual(try JSONDecoder().decode([Datacenter].self, from: defaults.data(forKey: "sole.datacenters") ?? Data()).first?.latency, 104)
        let next = self.model(defaults)
        XCTAssertEqual(next.resolution, 1440); XCTAssertEqual(next.bitrate, 22); XCTAssertEqual(next.catalogBackend, .ps3); XCTAssertEqual(next.filter, .favorites)
        XCTAssertEqual(next.selectedDatacenter, "tyob"); XCTAssertEqual(next.datacenterName("tyob"), localizedCity("Tokyo, Japan"))
    }

    @MainActor func testSwitchingToAPlatformWithoutTheOpenFilterShowsAllGames() async {
        let model = model(testSettings())
        model.filter = .recent
        model.catalogBackend = .psPlusPC
        XCTAssertEqual(model.filter, .recent)
        model.catalogBackend = .ps3
        XCTAssertEqual(model.filter, .all)
        XCTAssertEqual(model.availableLibraryFilters, [.all, .favorites])
    }

    @MainActor func testTheLibraryFollowsTheListsTheSearchAndTheFavorites() async {
        let defaults = testSettings()
        let model = model(defaults)
        let first = game("a", "Alpha"), second = game("b", "Beta"), old = game("pc:c", "Gamma", .psPlusPC)
        model.catalogGames = [first, second, old]
        XCTAssertEqual(model.orderedGames.map(\.id), ["a", "b"])
        model.search = "bet"
        XCTAssertEqual(model.filteredGames.map(\.id), ["b"])
        model.search = ""
        model.filter = .favorites
        XCTAssertTrue(model.filteredGames.isEmpty)
        model.toggleFavorite("a")
        XCTAssertEqual(model.filteredGames.map(\.id), ["a"])
        XCTAssertTrue(model.catalogGames[0].favorite)
        let next = self.model(defaults)
        next.catalogGames = [first]
        next.toggleFavorite("a")
        XCTAssertFalse(next.catalogGames[0].favorite, "It was a favorite: the second press takes it away")
        model.toggleFavorite("a")
        XCTAssertTrue(model.filteredGames.isEmpty)
        model.filter = .recent
        model.games = [second]
        XCTAssertEqual(model.filteredGames.map(\.id), ["b"])
        model.catalogBackend = .psPlusPC
        model.filter = .all
        XCTAssertEqual(model.orderedGames.map(\.id), ["pc:c"])
    }

    @MainActor func testAGameIsShownOpenedAndClosesTheSettings() async {
        let model = model(testSettings())
        let streamed = game("pc:re", "Resident Evil", .psPlusPC, product: "UP-CUSA1-RE")
        model.catalogGames = [streamed]
        model.showSettings(.stream)
        XCTAssertTrue(model.settingsOpen); XCTAssertEqual(model.settingsSection, .stream)
        model.openGame(game("CUSA1_00", "Resident Evil™", .psPlusPC))
        XCTAssertFalse(model.settingsOpen); XCTAssertTrue(model.gameOpen)
        XCTAssertEqual(model.selectedGame?.id, "pc:re", "The page of the catalog's own game")
        model.toggleFavorite("pc:re")
        XCTAssertEqual(model.selectedGame?.favorite, true)
    }

    @MainActor func testTheInterfaceIsToldBeforeEachChange() async {
        let model = model(testSettings())
        var told = 0
        var search: [String] = []
        model.willChange = { told += 1; search.append(model.search) }
        model.search = "x"
        XCTAssertEqual(told, 1); XCTAssertEqual(search, [""], "Before the change")
        model.settingsOpen = true; model.loginOpen = true; model.message = "m"; model.resolution = 720
        XCTAssertEqual(told, 5)
        model.catalogGames.append(game("a", "Alpha"))
        XCTAssertEqual(told, 6, "A list changed in place")
    }

    @MainActor func testTheListOfConsolesIsSearchedForOnlyWhileItIsShown() async {
        let player = Player()
        let model = model(testSettings(), player: player)
        XCTAssertNotNil(player.accountProvider); XCTAssertNotNil(player.cloudEnded)
        model.destination = .cloud
        XCTAssertEqual(player.calls, [], "Nothing changed")
        model.destination = .consoles
        guard Destination.consolesShown else {
            XCTAssertEqual(model.destination, .cloud, "Consoles are hidden while Destination.consolesShown is off")
            XCTAssertEqual(player.calls, [])
            return
        }
        model.destination = .cloud
        XCTAssertEqual(player.calls, ["startDiscovery", "stopDiscovery"])
    }

    @MainActor func testVibrationAndTheSizeOfThePictureReachWhatPlaysTheStream() async {
        let player = Player()
        let model = model(testSettings(), player: player)
        XCTAssertTrue(player.vibration); XCTAssertFalse(player.fillsWindow)
        model.haptics = false; model.videoFit = "fill"
        XCTAssertFalse(player.vibration, "At once: a stream may be running")
        XCTAssertTrue(player.fillsWindow)
        model.haptics = true; model.videoFit = "fit"
        XCTAssertTrue(player.vibration); XCTAssertFalse(player.fillsWindow)
        let saved = Player()
        _ = self.model(testSettings(["sole.haptics": false, "sole.videoFit": "fill"]), player: saved)
        XCTAssertFalse(saved.vibration); XCTAssertTrue(saved.fillsWindow)
    }

    @MainActor func testACloudGameNeedsAnAccountAndAProduct() async {
        let player = Player()
        let model = model(testSettings(), player: player)
        let played = game("NPUB1_00", "No product")
        model.connectCloud(game: played)
        XCTAssertFalse(model.connectingCloud); XCTAssertNil(model.cloudError, "Nobody is signed in: nothing happens")
        model.account = Account(profile)
        model.connectCloud(game: played)
        XCTAssertFalse(model.connectingCloud)
        XCTAssertEqual(model.cloudError, CloudFailure.noLicense)
        XCTAssertEqual(model.cloudLaunchingGame?.id, "NPUB1_00", "The launch screen shows the game chosen, not the one played before")
        XCTAssertEqual(player.calls, [])
        model.cancelCloud()
        XCTAssertNil(model.cloudError); XCTAssertNil(model.cloudLaunchingGame)
    }

    @MainActor private func settled(_ model: AppModel) async {
        for _ in 0..<200 where model.connectingCloud { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(model.connectingCloud)
    }

    @MainActor func testARestartForAGameWithoutSoundLeavesTheStreamAndStartsTheSameGame() async {
        let player = Player()
        let model = model(testSettings(), player: player)
        model.account = Account(profile)
        let wanted = game("PPSA1_00", "Wanted", product: "UP0001-PPSA00001_00-GAME000000000000")
        var started: [String?] = []
        model.prepareCloud = { game, _, _ in started.append(game?.id); return nil }
        model.connectCloud(game: wanted)
        await settled(model)
        player.calls = []
        player.cloudRestart?()
        await settled(model)
        XCTAssertEqual(player.calls.first, "disconnect")
        XCTAssertEqual(started, ["PPSA1_00", "PPSA1_00"])
    }

    @MainActor func testTheSessionOfAStreamJustLeftIsEndedByItselfAndAnotherIsWaitedFor() async {
        let player = Player()
        let defaults = testSettings()
        let model = model(defaults, player: player)
        model.previousSessionWait = 1_000_000
        model.account = Account(profile)
        let wanted = game("PPSA1_00", "Wanted", product: "UP0001-PPSA00001_00-GAME000000000000")
        var starts: [Bool] = []
        var answers: [Error?] = []
        model.prepareCloud = { _, force, progress in
            starts.append(force)
            progress("step")
            if let answer = answers.isEmpty ? nil : answers.removeFirst() { throw answer }
            return nil
        }

        answers = [CloudProtocol.Failure.sessionBusy, CloudProtocol.Failure.sessionBusy, nil]
        model.connectCloud(game: wanted)
        await settled(model)
        XCTAssertEqual(starts, [false, false, false])
        XCTAssertNil(model.cloudError)

        starts = []
        answers = Array(repeating: CloudProtocol.Failure.sessionBusy, count: AppModel.previousSessionTries + 1)
        model.connectCloud(game: wanted)
        await settled(model)
        XCTAssertEqual(starts, Array(repeating: false, count: AppModel.previousSessionTries + 1))
        XCTAssertEqual(model.cloudError, CloudFailure(CloudProtocol.Failure.sessionBusy).message)

        player.cloudEnded?(nil)
        starts = []
        answers = [CloudProtocol.Failure.sessionBusy, nil]
        model.connectCloud(game: wanted)
        await settled(model)
        XCTAssertEqual(starts, [false, true])
        XCTAssertNil(model.cloudError)

        starts = []
        answers = [CloudProtocol.Failure.serviceCode(400, "Server request", "002.2008", ""), nil]
        model.connectCloud(game: wanted)
        await settled(model)
        XCTAssertEqual(starts, [false, false])

        starts = []
        answers = [CloudProtocol.Failure.service(500, "Preparing the game session")]
        model.connectCloud(game: wanted)
        await settled(model)
        XCTAssertEqual(starts, [false]); XCTAssertNotNil(model.cloudError); XCTAssertTrue(model.cloudCanRetry)
        model.previousSessionWait = 2_000_000_000
        defaults.removeObject(forKey: AppModel.streamEndedKey)
        starts = []
        answers = [CloudProtocol.Failure.sessionBusy, nil]
        model.connectCloud(game: wanted)
        for _ in 0..<100 where starts.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
        model.cancelCloud()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(starts, [false]); XCTAssertFalse(model.connectingCloud)
        XCTAssertEqual(player.calls, [])
    }

    @MainActor func testTheEndOfAStreamIsSaidOnTheGamesPage() async {
        let player = Player()
        let model = model(testSettings(), player: player)
        player.cloudEnded?(nil)
        XCTAssertEqual(model.cloudStatus, Localization.text("Stream ended.", in: .english)); XCTAssertNil(model.cloudError)
        player.cloudEnded?("the line dropped")
        XCTAssertNil(model.cloudStatus)
        XCTAssertEqual(model.cloudError, Localization.text("Stream interrupted: %@", values: ["the line dropped"], in: .english))
    }

    @MainActor func testWithoutAStoredSignInTheAppOpensSignedOutAndAsksOnce() async {
        let model = model(testSettings())
        await model.restoreAccount()
        XCTAssertNil(model.account); XCTAssertNil(model.authError); XCTAssertFalse(model.restoringAccount)
        XCTAssertFalse(model.loadingLibrary); XCTAssertFalse(model.loadingOwned)
        model.reloadLibrary(); model.reloadOwned()
        XCTAssertFalse(model.loadingLibrary, "Nobody is signed in")
        XCTAssertFalse(model.loadingOwned)
    }

    @MainActor func testAClosedSignInPageSaysSoAndCanBeOpenedAgain() async throws {
        let page = Page()
        let model = model(testSettings(), page: page)
        model.signIn()
        XCTAssertTrue(model.signingIn)
        model.signIn()
        for _ in 0..<200 where model.signingIn { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(model.signingIn)
        XCTAssertEqual(page.opened, 1, "A second press while the page is open does nothing")
        XCTAssertEqual(model.authError, PSNAuthorization.AuthError.cancelled.errorDescription)
        XCTAssertNil(model.account)
        model.signIn()
        XCTAssertNil(model.authError, "A new attempt starts clean")
        model.cancelSignIn()
        XCTAssertFalse(model.signingIn); XCTAssertGreaterThanOrEqual(page.cancelled, 1)
    }

    @MainActor func testSigningOutStopsTheStreamForgetsTheAccountAndKeepsThePS5Catalog() async throws {
        let store = MemoryStore(), player = Player(), defaults = testSettings(["sole.datacenter": "auto"])
        await store.put(Data("token".utf8), PSNAuthorization.refreshAccount)
        let model = model(defaults, store: store, player: player)
        model.account = Account(profile)
        model.games = [game("a", "Alpha")]
        model.catalogGames = [game("concept:1", "Alpha", concept: 1), game("pc:b", "Beta", .psPlusPC)]
        model.datacenters = [Datacenter(id: "fraa", latency: 30)]; model.selectedDatacenter = "fraa"
        model.signOut()
        XCTAssertTrue(model.signingOut)
        model.signOut()
        for _ in 0..<200 where model.signingOut { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(model.signingOut)
        XCTAssertEqual(player.calls, ["disconnect"], "Once")
        XCTAssertNil(model.account); XCTAssertTrue(model.games.isEmpty); XCTAssertTrue(model.owned.isEmpty)
        XCTAssertEqual(model.catalogGames.map(\.id), ["concept:1"], "The catalog of the PS4 and PS3 clouds was the account's")
        XCTAssertTrue(model.datacenters.isEmpty); XCTAssertEqual(model.selectedDatacenter, "auto")
        let left = await store.records
        XCTAssertTrue(left.isEmpty, "The sign-in is gone from the store")
        XCTAssertNil(model.message)
    }
}
