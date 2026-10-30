import Foundation
import SoleCloud
import SoleCore
import SoleEngine

@MainActor public protocol StreamPlayer: AnyObject {
    var accountProvider: (() async throws -> [UInt8])? { get set }
    var cloudEnded: ((String?) -> Void)? { get set }
    var cloudRestart: (() -> Void)? { get set }
    func connectCloud(_ stream: CloudStream)
    func disconnect()
    func showTrophy(_ notice: TrophyNotice)
    var vibration: Bool { get set }
    var fillsWindow: Bool { get set }
    var hasControls: Bool { get }
    func startDiscovery()
    func stopDiscovery()
}

public extension StreamPlayer {
    func showTrophy(_ notice: TrophyNotice) {}
}

public enum SettingsSection: String, CaseIterable, Identifiable, Sendable {
    case general = "General", account = "PSN Account", stream = "Stream", controller = "Controls", about = "About Con"
    public var id: String { rawValue }
}

@MainActor open class AppModel {
    public var willChange: (() -> Void)?
    private func changing() { willChange?() }

    private let authorization: PSNAuthorization
    private let cloudAuthorization = CloudAuthorization()
    private let player: StreamPlayer
    private let defaults: UserDefaults

    public init(store: CredentialStore, website: SonyLoginPage, player: StreamPlayer, defaults: UserDefaults = .standard,
                caches: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("Sole")) {
        authorization = PSNAuthorization(store: store, website: website)
        self.player = player
        self.defaults = defaults
        catalogService = CloudCatalogService(cacheDirectory: caches?.appendingPathComponent("catalog"))
        func stored(_ key: String) -> Bool { defaults.object(forKey: key) != nil }
        catalogLocale = defaults.string(forKey: "sole.catalogLocale") ?? "en-us"
        favoriteIDsData = defaults.data(forKey: "sole.favorites") ?? Data()
        language = defaults.string(forKey: AppLanguage.storageKey) ?? AppLanguage.english.rawValue
        videoFit = defaults.string(forKey: "sole.videoFit") ?? "fit"
        resolution = stored("sole.resolution") ? defaults.integer(forKey: "sole.resolution") : 1080
        bitrate = stored("sole.bitrate") ? defaults.double(forKey: "sole.bitrate") : 30
        haptics = stored("sole.haptics") ? defaults.bool(forKey: "sole.haptics") : true
        distantServers = defaults.bool(forKey: Self.distantServersKey)
        trophyNotices = stored(Self.trophyNoticesKey) ? defaults.bool(forKey: Self.trophyNoticesKey) : true
        touchGamepad = stored("sole.touchGamepad") ? defaults.bool(forKey: "sole.touchGamepad") : true
        gameLanguage = defaults.string(forKey: "sole.gameLanguage").flatMap { GameLanguage.isKnown($0) ? $0 : nil } ?? GameLanguage.standard
        owned = (try? JSONDecoder().decode(OwnedLibrary.self, from: defaults.data(forKey: "sole.ownedLibrary") ?? Data())) ?? OwnedLibrary()
        trophies = try? JSONDecoder().decode(AccountTrophies.self, from: defaults.data(forKey: "sole.trophies") ?? Data())
        let savedBackend = defaults.string(forKey: "con.catalogBackend")
        filter = Library.filter(saved: defaults.string(forKey: "sole.libraryFilter"), backend: savedBackend)
        catalogBackend = savedBackend.flatMap(CloudBackend.init(rawValue:)) ?? .ps5
        let centers = (try? JSONDecoder().decode([Datacenter].self, from: defaults.data(forKey: "sole.datacenters") ?? Data())) ?? []
        datacenters = centers
        let chosen = defaults.string(forKey: "sole.datacenter") ?? Self.automaticDatacenter
        selectedDatacenter = chosen == Self.automaticDatacenter || centers.contains(where: { $0.id == chosen }) ? chosen : Self.automaticDatacenter
        if selectedDatacenter != chosen { defaults.set(selectedDatacenter, forKey: "sole.datacenter") }

        player.vibration = haptics
        player.fillsWindow = videoFit == Self.fill
        player.accountProvider = { [authorization] in try await authorization.psnAccountIDBytes() }
        player.cloudEnded = { [weak self] failure in
            guard let self else { return }
            self.defaults.set(Date().timeIntervalSince1970, forKey: Self.streamEndedKey)
            self.cloudLaunchSlot = nil; self.cloudAuthorization.cancel()
            self.cloudStatus = failure == nil ? loc("Stream ended.") : nil
            self.cloudError = failure.map { loc("Stream interrupted: %@", $0) }
            self.trophyWatchTask?.cancel(); self.trophyWatchTask = nil
        }
        player.cloudRestart = { [weak self] in self?.restartCloud() }
    }

    struct TrophySource {
        var titles: () async throws -> (status: Int, titles: [TrophyTitle])
        var earned: (TrophyTitle) async throws -> (status: Int, trophies: [EarnedTrophy])
        var defined: (TrophyTitle) async throws -> (status: Int, trophies: [TrophyDefinition])
    }
    var trophySource: TrophySource?
    var trophyInterval: UInt64 = 30_000_000_000
    static let trophyTries = 3
    private var trophyWatchTask: Task<Void, Never>?
    func watchTrophies() {
        trophyWatchTask?.cancel(); trophyWatchTask = nil
        guard trophyNotices else { return }
        let language = language
        let source = trophySource ?? TrophySource(
            titles: { [authorization] in try await authorization.trophyTitles(limit: 8) },
            earned: { [authorization] in try await authorization.earnedTrophies(of: $0) },
            defined: { [authorization] in try await authorization.definedTrophies(of: $0, language: language) })
        let interval = trophyInterval, sony = trophySource == nil
        trophyWatchTask = Task { [weak player] in
            var watch = TrophyWatch(since: Date())
            var definitions: [String: [TrophyDefinition]] = [:]
            var statuses: [String: Int] = [:]
            var pending: [(title: TrophyTitle, tries: Int)] = []
            while !Task.isCancelled {
                if let answer = try? await source.titles() {
                    statuses["titles"] = answer.status
                    for title in watch.grown(answer.titles) {
                        pending.removeAll { $0.title.id == title.id }
                        pending.append((title, 0))
                    }
                    var kept: [(title: TrophyTitle, tries: Int)] = []
                    for (title, tries) in pending {
                        guard !Task.isCancelled else { return }
                        let earned = try? await source.earned(title)
                        statuses["earned"] = earned?.status ?? 0
                        if definitions[title.id] == nil, let defined = try? await source.defined(title) {
                            statuses["defined"] = defined.status
                            if !defined.trophies.isEmpty { definitions[title.id] = defined.trophies }
                        }
                        let notices = watch.notices(title, earned: earned?.trophies ?? [], defined: definitions[title.id] ?? [])
                        statuses["shown", default: 0] += notices.count
                        guard !Task.isCancelled else { return }
                        for notice in notices { player?.showTrophy(notice) }
                        let answered = earned.map { (200..<300).contains($0.status) } ?? false
                        if !(answered && !notices.isEmpty), tries + 1 < Self.trophyTries { kept.append((title, tries + 1)) }
                    }
                    pending = kept
                    if sony { Self.recordTrophyWatch(statuses) }
                }
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }
    private static func recordTrophyWatch(_ statuses: [String: Int]) {
        Diagnostics.write(statuses, named: "trophy-watch.json")
    }

    public func restartCloud() {
        guard let game = cloudLaunchingGame else { player.disconnect(); return }
        player.disconnect()
        connectCloud(game: game)
    }

    private var cloudTask: Task<Void, Never>?
    private var cloudAttempt: UUID?
    public var connectingCloud = false { willSet { changing() } }
    public private(set) var cloudLaunchingGame: Game? { willSet { changing() } }
    public var cloudStatus: String? { willSet { changing() } }
    public var cloudError: String? { willSet { changing() } }
    public var cloudCanRetry = false { willSet { changing() } }
    static let streamEndedKey = "sole.cloudStreamEndedAt"
    static let ownSessionWindow: TimeInterval = 180
    static let previousSessionTries = 6
    var previousSessionWait: UInt64 = 15_000_000_000
    public private(set) var cloudLaunchSlot: CloudLaunchSlot?
    var prepareCloud: (@MainActor (_ game: Game?, _ forceLogout: Bool, _ progress: @escaping (String) -> Void) async throws -> CloudAuthorization.Preparation?)?
    public func connectCloud(game: Game? = nil) {
        guard account != nil, !connectingCloud else { return }
        let game = game.map { Library.startable($0, in: catalogGames) }
        if let game, !Library.canStart(game) {
            cloudLaunchingGame = game; cloudStatus = nil; cloudCanRetry = false
            cloudError = CloudFailure.noLicense
            return
        }
        startCloud(game)
    }
    private var ownSessionJustEnded: Bool {
        guard let ended = defaults.object(forKey: Self.streamEndedKey) as? Double else { return false }
        let since = Date().timeIntervalSince1970 - ended
        return since >= 0 && since < Self.ownSessionWindow
    }
    private func startCloud(_ game: Game?) {
        cloudLaunchingGame = game
        let attempt = UUID(); cloudAttempt = attempt
        connectingCloud = true; cloudError = nil; cloudCanRetry = false; cloudLaunchSlot = nil
        cloudTask = Task { [self] in
            defer { if cloudAttempt == attempt { connectingCloud = false; cloudTask = nil; cloudAttempt = nil } }
            var forceLogout = false, waited = 0
            while true {
                do {
                    let progress: (String) -> Void = { [weak self] stage in
                        if self?.cloudAttempt == attempt { self?.cloudStatus = stage }
                    }
                    let result: CloudAuthorization.Preparation?
                    if let prepareCloud {
                        result = try await prepareCloud(game, forceLogout, progress)
                    } else {
                        let preferred = selectedDatacenter == Self.automaticDatacenter ? nil : selectedDatacenter
                        let onDatacenters: ([CloudDatacenter], [String: Int]) -> Void = { [weak self] centers, latencies in
                            guard let self, self.cloudAttempt == attempt else { return }
                            self.show(centers, latencies)
                        }
                        result = try await cloudAuthorization.connect(
                            credential: { try await self.authorization.cloudSSO() },
                            entitlementID: game?.productID,
                            conceptID: game?.conceptID,
                            title: game?.title,
                            backend: game?.cloudBackend ?? .ps5,
                            isPlusMember: self.account?.isPlus ?? true,
                            height: self.resolution,
                            bitrateKbps: Int(self.bitrate * 1000),
                            language: self.gameLanguage,
                            preferredDatacenter: preferred,
                            distantServers: self.distantServers,
                            forceLogout: forceLogout,
                            onDatacenters: onDatacenters,
                            progress: progress)
                    }
                    guard cloudAttempt == attempt, !Task.isCancelled else { return }
                    if let result {
                        show(result.centers, result.latencies)
                        cloudLaunchSlot = result.slot
                        let stream = CloudStream(result, game: game, height: resolution)
                        cloudStatus = stream.status
                        player.connectCloud(stream)
                        if player.hasControls { watchTrophies() }
                    } else {
                        cloudStatus = loc("PS Cloud sign-in confirmed. Choose a game to prepare a stream.")
                    }
                    return
                } catch {
                    guard cloudAttempt == attempt, !Task.isCancelled else { return }
                    let other = game.flatMap { Library.elsewhere($0, in: catalogGames) }
                    let failure = CloudFailure(error, automaticServer: selectedDatacenter == Self.automaticDatacenter, elsewhere: other.map { ($0.cloudBackend.console, isOwned($0)) })
                    if failure.waitsForPreviousSession, game != nil {
                        if case CloudProtocol.Failure.sessionBusy = error, !forceLogout, ownSessionJustEnded {
                            forceLogout = true
                            cloudStatus = loc("Ending the other session…")
                            continue
                        }
                        if waited < Self.previousSessionTries {
                            waited += 1
                            cloudStatus = loc("The previous session has not closed yet. Trying again in %@ s (attempt %@ of %@)", Int(previousSessionWait / 1_000_000_000), waited, Self.previousSessionTries)
                            try? await Task.sleep(nanoseconds: previousSessionWait)
                            guard cloudAttempt == attempt, !Task.isCancelled else { return }
                            continue
                        }
                    }
                    cloudStatus = nil
                    cloudError = failure.message; cloudCanRetry = failure.canRetry
                    return
                }
            }
        }
    }
    private func show(_ centers: [CloudDatacenter], _ latencies: [String: Int]) {
        datacenters = centers.map { Datacenter(id: $0.id, latency: latencies[$0.id]) }
        if selectedDatacenter != Self.automaticDatacenter, !datacenters.contains(where: { $0.id == selectedDatacenter }) {
            selectedDatacenter = Self.automaticDatacenter
        }
    }
    public func cancelCloud() {
        cloudAttempt = nil; cloudTask?.cancel(); cloudTask = nil
        cloudAuthorization.cancel(); cloudLaunchSlot = nil
        connectingCloud = false; cloudLaunchingGame = nil; cloudStatus = nil; cloudError = nil; cloudCanRetry = false
    }

    private var authTask: Task<Void, Never>?
    private var libraryTask: Task<Void, Never>?
    private var authAttempt: UUID?
    private var accountRevision = 0
    private var didRestore = false
    public var account: Account? { willSet { changing() } }
    public var signingOut = false { willSet { changing() } }
    public var restoringAccount = false { willSet { changing() } }
    public var signingIn = false { willSet { changing() } }
    public var authError: String? { willSet { changing() } }
    public var loginOpen = false { willSet { changing() } }
    public func signIn() {
        guard !signingIn, !restoringAccount, !signingOut else { return }
        cancelCloud()
        let attempt = UUID()
        authAttempt = attempt
        accountRevision += 1
        libraryTask?.cancel(); libraryTask = nil; loadingLibrary = false
        trophiesTask?.cancel(); trophiesTask = nil; trophiesAttempt = nil; loadingTrophies = false
        signingIn = true; authError = nil
        authTask = Task {
            defer { if authAttempt == attempt { signingIn = false; authTask = nil; authAttempt = nil } }
            do {
                let profile = try await authorization.signIn()
                guard authAttempt == attempt, !Task.isCancelled else { return }
                account = Account(profile); loginOpen = false
                await loadAccountData()
            } catch {
                guard authAttempt == attempt, !Task.isCancelled else { return }
                authError = (error as? PSNAuthorization.AuthError)?.errorDescription ?? loc("Could not reach PlayStation. Try again.")
            }
        }
    }
    public func cancelSignIn() {
        guard signingIn else { return }
        authAttempt = nil
        authTask?.cancel(); authTask = nil
        authorization.cancel()
        signingIn = false; authError = nil
    }
    public func restoreAccount() async {
        guard !didRestore else { return }
        didRestore = true
        restoringAccount = true
        defer { restoringAccount = false }
        let revision = accountRevision
        do {
            if let profile = try await authorization.restore(), revision == accountRevision {
                account = Account(profile)
                await loadAccountData()
            }
        } catch {
            guard revision == accountRevision else { return }
            authError = (error as? PSNAuthorization.AuthError)?.errorDescription ?? loc("Could not restore your sign-in. Check the connection and try again.")
        }
    }
    private func loadAccountData() async {
        reloadLibrary()
        reloadOwned()
        await loadPCCatalog(attempt: nil)
    }
    public func signOut() {
        guard !signingOut else { return }
        signingOut = true
        player.disconnect()
        cancelCloud()
        cancelSignIn()
        accountRevision += 1
        libraryTask?.cancel(); libraryTask = nil; loadingLibrary = false; libraryError = nil
        trophiesTask?.cancel(); trophiesTask = nil; trophiesAttempt = nil; loadingTrophies = false
        trophyWatchTask?.cancel(); trophyWatchTask = nil
        Task {
            defer { signingOut = false }
            do {
                try await authorization.signOut()
                await cloudAuthorization.clearPCCatalog()
                account = nil
                games = []
                recentGames = []
                catalogGames.removeAll { $0.cloudBackend != .ps5 }
                pcCatalogError = nil
                owned = OwnedLibrary()
                datacenters = []
                selectedDatacenter = Self.automaticDatacenter
                trophies = nil
                trophiesFailure = nil
            } catch {
                message = error.localizedDescription
            }
        }
    }

    public var games: [Game] = [] { willSet { changing() } didSet { invalidateLibraryCache() } }
    public var loadingLibrary = false { willSet { changing() } }
    public var libraryError: String? { willSet { changing() } }
    public private(set) var recentGames: [AccountPage.RecentGame] = [] { willSet { changing() } }
    public func reloadLibrary() {
        reloadTrophies()
        guard account != nil, !loadingLibrary else { return }
        let revision = accountRevision
        loadingLibrary = true; libraryError = nil
        libraryTask = Task {
            defer { if revision == accountRevision { loadingLibrary = false; libraryTask = nil } }
            do {
                let titles = try await authorization.playedGames()
                guard revision == accountRevision, !Task.isCancelled else { return }
                games = Library.games(history: titles, favorites: favoriteIDs)
                recentGames = AccountPage.recent(titles, favorites: favoriteIDs)
            } catch {
                guard revision == accountRevision, !Task.isCancelled else { return }
                libraryError = loc("Could not load recent games. Try refreshing the library.")
            }
        }
    }
    public private(set) var owned: OwnedLibrary {
        willSet { changing() }
        didSet { invalidateLibraryCache(); defaults.set(try? JSONEncoder().encode(owned), forKey: "sole.ownedLibrary"); supplementStreamingCatalog() }
    }
    public private(set) var loadingOwned = false { willSet { changing() } }
    private var ownedTask: Task<Void, Never>?
    public func reloadOwned() {
        guard account != nil, ownedTask == nil else { return }
        let revision = accountRevision
        loadingOwned = true
        ownedTask = Task {
            defer { ownedTask = nil; loadingOwned = false }
            guard let titles = try? await cloudAuthorization.ownedTitles(credential: { try await self.authorization.cloudSSO() }),
                  revision == accountRevision, !Task.isCancelled else { return }
            owned = OwnedLibrary(titles)
        }
    }
    public func isOwned(_ game: Game) -> Bool { Library.isOwned(game, by: owned, claimed: claimedNames) }
    private var claimedNamesCache: Library.ClaimedNames?
    private var claimedNames: Library.ClaimedNames {
        if let claimedNamesCache { return claimedNamesCache }
        let names = Library.ClaimedNames(owned, catalog: catalogGames)
        claimedNamesCache = names
        return names
    }

    public private(set) var trophies: AccountTrophies? {
        willSet { changing() }
        didSet {
            if let trophies {
                defaults.set(try? JSONEncoder().encode(trophies), forKey: "sole.trophies")
            } else {
                defaults.removeObject(forKey: "sole.trophies")
            }
        }
    }
    public private(set) var loadingTrophies = false { willSet { changing() } }
    public private(set) var trophiesFailure: AccountPage.TrophyFailure? { willSet { changing() } }
    private var trophiesTask: Task<Void, Never>?
    private var trophiesAttempt: UUID?
    var fetchTrophies: (@MainActor () async throws -> PSNAuthorization.TrophyResponse)?
    public func reloadTrophies() {
        guard account != nil, trophiesTask == nil else { return }
        let revision = accountRevision, attempt = UUID()
        trophiesAttempt = attempt
        loadingTrophies = true
        trophiesTask = Task {
            defer { if trophiesAttempt == attempt { trophiesTask = nil; trophiesAttempt = nil; loadingTrophies = false } }
            let answer: PSNAuthorization.TrophyResponse
            do {
                if let fetchTrophies {
                    answer = try await fetchTrophies()
                } else {
                    answer = try await authorization.trophies(titles: AccountPage.trophyTitlesCount)
                }
            } catch {
                guard revision == accountRevision, !Task.isCancelled else { return }
                trophiesFailure = .failed
                return
            }
            guard revision == accountRevision, !Task.isCancelled else { return }
            if fetchTrophies == nil { AccountPage.recordDiagnostics(summaryStatus: answer.summaryStatus, titlesStatus: answer.titlesStatus, read: answer.trophies != nil) }
            if let read = answer.trophies {
                trophies = read
                trophiesFailure = nil
            } else {
                trophiesFailure = [401, 403].contains(answer.summaryStatus) ? .refused : .failed
            }
        }
    }

    private var favoriteIDsData: Data { willSet { changing() } didSet { defaults.set(favoriteIDsData, forKey: "sole.favorites") } }
    private var favoriteIDs: Set<String> {
        get { Set((try? JSONDecoder().decode([String].self, from: favoriteIDsData)) ?? []) }
        set { favoriteIDsData = (try? JSONEncoder().encode(newValue.sorted())) ?? Data() }
    }
    public func toggleFavorite(_ id: String) {
        var ids = favoriteIDs
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        favoriteIDs = ids
        for index in games.indices where games[index].id == id { games[index].favorite = ids.contains(id) }
        for index in catalogGames.indices where catalogGames[index].id == id { catalogGames[index].favorite = ids.contains(id) }
        if selectedGame?.id == id { selectedGame?.favorite = ids.contains(id) }
    }

    private let catalogService: CloudCatalogService
    private var catalogTask: Task<Void, Never>?
    private var catalogAttempt: UUID?
    private var unconfirmedCatalog: [CloudTitle] = []
    private let storeStreaming = StoreStreamingService()
    private var streamingCatalogTask: Task<Void, Never>?
    public var catalogGames: [Game] = [] { willSet { changing() } didSet { invalidateLibraryCache() } }
    public var loadingCatalog = false { willSet { changing() } }
    public var catalogError: String? { willSet { changing() } }
    public var catalogLocale: String { willSet { changing() } didSet { defaults.set(catalogLocale, forKey: "sole.catalogLocale") } }
    public private(set) var pcCatalogError: String? { willSet { changing() } }
    public private(set) var loadingPCCatalog = false { willSet { changing() } }
    public func reloadCatalog(force: Bool = false) {
        catalogTask?.cancel()
        let attempt = UUID()
        catalogAttempt = attempt
        let locale = catalogLocale
        loadingCatalog = true; catalogError = nil
        catalogTask = Task {
            defer { if catalogAttempt == attempt { loadingCatalog = false; catalogTask = nil } }
            do {
                let result = try await catalogService.load(locale: locale, force: force)
                guard catalogAttempt == attempt, !Task.isCancelled else { return }
                unconfirmedCatalog = result.unconfirmed
                let favorites = favoriteIDs
                catalogGames = result.titles.map { Library.game($0, favorites: favorites) } + catalogGames.filter { $0.cloudBackend != .ps5 }
                if account != nil { await loadPCCatalog(attempt: attempt, force: force) }
            } catch {
                guard catalogAttempt == attempt, !Task.isCancelled else { return }
                catalogError = loc("Could not load the Sony catalog. Check the connection and try refreshing it.")
            }
        }
    }
    private func loadPCCatalog(attempt: UUID?, force: Bool = false) async {
        guard account != nil, !loadingPCCatalog else { return }
        let revision = accountRevision
        loadingPCCatalog = true
        defer { loadingPCCatalog = false }
        do {
            let titles = try await cloudAuthorization.pcTitles(force: force, credential: { try await self.authorization.cloudSSO() })
            guard account != nil, accountRevision == revision, !Task.isCancelled, attempt == nil || catalogAttempt == attempt else { return }
            catalogGames = Library.catalog(catalogGames, replacingStreamed: titles, favorites: favoriteIDs)
            pcCatalogError = nil
            supplementStreamingCatalog()
        } catch {
            guard !Task.isCancelled, account != nil, accountRevision == revision, attempt == nil || catalogAttempt == attempt else { return }
            pcCatalogError = loc("Could not load the PS Plus PC catalog. Try refreshing the catalog.")
        }
    }
    private func supplementStreamingCatalog() {
        streamingCatalogTask?.cancel()
        let candidates = Library.streamingCandidates(unconfirmedCatalog, owned: owned, history: games, query: search)
        let locale = catalogLocale, revision = accountRevision
        streamingCatalogTask = Task {
            for title in candidates {
                guard !Task.isCancelled else { return }
                guard (try? await storeStreaming.supports(title, locale: locale)) == true else { continue }
                guard !Task.isCancelled, revision == accountRevision, locale == catalogLocale else { return }
                if !catalogGames.contains(where: { $0.id == title.id }) {
                    catalogGames.append(Library.game(title, favorites: favoriteIDs, platform: "PS5"))
                }
            }
        }
    }
    public func pcScreenshots(for game: Game) async -> [URL] {
        guard let product = game.productID else { return [] }
        return (try? await cloudAuthorization.pcScreenshots(productID: product)) ?? []
    }
    private let storeScreenshots = StoreScreenshotService()
    public func screenshots(for game: Game) async -> [URL] {
        if game.cloudBackend != .ps5 { return await pcScreenshots(for: game) }
        guard let concept = game.conceptID else { return [] }
        return (try? await storeScreenshots.screenshots(conceptID: concept, locale: catalogLocale)) ?? []
    }

    public var destination: Destination = .cloud {
        willSet { changing() }
        didSet {
            if destination == .consoles, !Destination.consolesShown { destination = .cloud }
            guard destination != oldValue else { return }
            if destination == .consoles { player.startDiscovery() } else { player.stopDiscovery() }
        }
    }
    public var streamHasControls: Bool { player.hasControls }
    public var selectedGame: Game? { willSet { changing() } }
    public var gameOpen = false { willSet { changing() } }
    public func openGame(_ game: Game) {
        let game = Library.page(for: game, in: catalogGames)
        showGame(game); gameOpen = true
    }
    public func showGame(_ game: Game) {
        if settingsOpen { settingsOpen = false }
        guard selectedGame?.id != game.id else { return }
        selectedGame = game
    }
    public var settingsOpen = false { willSet { changing() } }
    public var settingsSection: SettingsSection = .general { willSet { changing() } }
    public func showSettings(_ section: SettingsSection = .general) {
        settingsSection = section; settingsOpen = true
    }
    public var message: String? { willSet { changing() } }

    public var search = "" { willSet { changing() } didSet { invalidateLibraryCache(); supplementStreamingCatalog() } }
    public var filter: LibraryFilter {
        willSet { changing() }
        didSet { invalidateLibraryCache(); defaults.set(filter.rawValue, forKey: "sole.libraryFilter") }
    }
    public var catalogBackend: CloudBackend {
        willSet { changing() }
        didSet {
            invalidateLibraryCache()
            if !availableLibraryFilters.contains(filter) { filter = .all }
            defaults.set(catalogBackend.rawValue, forKey: "con.catalogBackend")
        }
    }
    public var availableLibraryFilters: [LibraryFilter] { Library.filters(for: catalogBackend) }
    private var filteredLibraryCache: [Game]?
    private var orderedLibraryCache: [Game]?
    private func invalidateLibraryCache() { filteredLibraryCache = nil; orderedLibraryCache = nil; claimedNamesCache = nil }
    public var orderedGames: [Game] {
        if let orderedLibraryCache { return orderedLibraryCache }
        let result = Library.ordered(filteredGames, filter: filter, search: search)
        orderedLibraryCache = result
        return result
    }
    public var filteredGames: [Game] {
        if let filteredLibraryCache { return filteredLibraryCache }
        let result = Library.listed(filter, backend: catalogBackend, search: search, catalog: catalogGames, history: games, isOwned: isOwned)
        filteredLibraryCache = result
        return result
    }

    public var language: String { willSet { changing() } didSet { defaults.set(language, forKey: AppLanguage.storageKey) } }
    public var videoFit: String { willSet { changing() } didSet { defaults.set(videoFit, forKey: "sole.videoFit"); player.fillsWindow = videoFit == Self.fill } }
    public static let fill = "fill"
    static let automaticDatacenter = "auto"
    public var resolution: Int { willSet { changing() } didSet { defaults.set(resolution, forKey: "sole.resolution") } }
    public var bitrate: Double { willSet { changing() } didSet { defaults.set(bitrate, forKey: "sole.bitrate") } }
    public var trophyNotices: Bool {
        willSet { changing() }
        didSet {
            defaults.set(trophyNotices, forKey: Self.trophyNoticesKey)
            if !trophyNotices {
                trophyWatchTask?.cancel(); trophyWatchTask = nil
            } else if !oldValue, player.hasControls, cloudLaunchSlot != nil {
                watchTrophies()
            }
        }
    }
    static let trophyNoticesKey = "sole.trophyNotices"
    public var haptics: Bool { willSet { changing() } didSet { defaults.set(haptics, forKey: "sole.haptics"); player.vibration = haptics } }
    public var distantServers: Bool { willSet { changing() } didSet { defaults.set(distantServers, forKey: Self.distantServersKey) } }
    static let distantServersKey = "sole.distantServers"
    public var gameLanguage: String { willSet { changing() } didSet { defaults.set(gameLanguage, forKey: "sole.gameLanguage") } }
    public var touchGamepad: Bool { willSet { changing() } didSet { defaults.set(touchGamepad, forKey: "sole.touchGamepad") } }
    public func selectPreset(_ height: Int) {
        resolution = height
        bitrate = StreamQuality.bitrate(height: height)
    }
    public var datacenters: [Datacenter] {
        willSet { changing() }
        didSet { defaults.set(try? JSONEncoder().encode(datacenters), forKey: "sole.datacenters") }
    }
    public var selectedDatacenter: String { willSet { changing() } didSet { defaults.set(selectedDatacenter, forKey: "sole.datacenter") } }
    public func datacenterName(_ id: String) -> String { Datacenter.name(id, among: datacenters.map(\.id)) }
    public var datacenterChoices: [(String, String)] {
        [("auto", loc("Automatic"))] + datacenters.map { ($0.id, datacenterName($0.id) + ($0.latency.map { loc(" · %@ ms", $0) } ?? "")) }
    }
    public var datacenterCaption: String {
        datacenters.isEmpty ? loc("The list appears after a stream is prepared for the first time") : loc("The server for cloud games · the choice is kept")
    }
    public var datacenterNote: String {
        cloudError ?? cloudStatus ?? (account == nil ? loc("Sign in to PlayStation to connect the cloud.")
            : datacenters.isEmpty ? loc("Sony sends the list of servers when a stream is prepared. After the first attempt it is kept here.")
            : loc("Choose the server for the next game. The latency is from the last check."))
    }
}
