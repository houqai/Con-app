import Foundation
import SoleCore
import SoleEngine

@MainActor open class LibraryScreen {
    public let model: AppModel
    public let focus: FocusModel
    public var willChange: (() -> Void)?

    public init(model: AppModel, focus: FocusModel) { self.model = model; self.focus = focus }

    public enum Target {
        public static let gamePrefix = "game:"
        public static func game(_ id: String) -> String { gamePrefix + id }
        public static let more = "more-games", pagePlay = "page-play", launchCancel = "launch-cancel", search = "search"
        public static func filter(_ filter: LibraryFilter) -> String { "filter:" + filter.rawValue }
        public static let settingsTabPrefix = "settings-tab:"
        public static func settingsTab(_ section: SettingsSection) -> String { settingsTabPrefix + section.id }
        public static let recentPrefix = "recent:"
        public static func recent(_ id: String) -> String { recentPrefix + id }
    }

    public static let rowsStep = 3
    private static let favoriteLetters: Set<String> = ["f", "а"]
    public private(set) var visibleRows = LibraryScreen.rowsStep { willSet { willChange?() } }
    public var columns = 6 { didSet { if columns != oldValue { clampSelection() } } }
    public var games: [Game] { model.orderedGames }
    public var visibleCount: Int { visibleRows * columns }
    public var hasMore: Bool { games.count > visibleCount }
    public var game: Game? { model.selectedGame ?? games.first }
    public var gamePageOpen: Bool { model.gameOpen && model.destination == .cloud }

    public var emptyText: String {
        if model.catalogGames.isEmpty, model.loadingCatalog { return loc("Loading the Sony catalog…") }
        guard model.filter == .owned, model.search.isEmpty else { return loc("No games found") }
        if model.account == nil { return loc("Sign in to PlayStation to see your purchased games.") }
        if model.loadingOwned || model.loadingCatalog { return loc("Loading your games…") }
        return loc("None of the games in the cloud catalog are among your purchases.")
    }

    public func startOver() { visibleRows = Self.rowsStep }
    public func catalogReplaced() { startOver(); model.selectedGame = nil }

    public func showMore() {
        let firstNew = visibleCount
        visibleRows += Self.rowsStep
        if focus.selected == Target.more, games.indices.contains(firstNew) {
            let next = games[firstNew]
            model.showGame(next)
            focus.selected = Target.game(next.id)
        }
    }

    public func clampSelection() {
        let games = games
        let limit = min(games.count, visibleCount)
        guard limit > 0, let index = games.firstIndex(where: { $0.id == game?.id }), index >= limit else { return }
        model.showGame(games[limit - 1])
        if focus.selected?.hasPrefix(Target.gamePrefix) == true { focus.selected = Target.game(games[limit - 1].id) }
    }

    public var destinationChoices: [FocusModel.Choice] {
        guard Destination.consolesShown else { return [] }
        let model = self.model
        return [
            .init(title: loc("Cloud games"), action: { model.destination = .cloud }),
            .init(title: loc("My consoles"), action: { model.destination = .consoles }),
        ]
    }
    public func appChoices(settingsOpened: @escaping () -> Void = {}) -> [FocusModel.Choice] {
        let model = self.model
        return [
            .init(title: loc("Refresh library"), action: { model.reloadCatalog(force: true); model.reloadLibrary() }),
            .init(title: loc("Settings"), action: { model.showSettings(); settingsOpened() }),
            .init(title: loc(SettingsSection.account.rawValue), action: { model.showSettings(.account); settingsOpened() }),
        ]
    }

    public func settingsChanged(open: Bool) {
        focus.selected = open ? Target.settingsTab(model.settingsSection) : model.gameOpen ? Target.pagePlay : nil
    }
    public func gamePageChanged(open: Bool) {
        focus.selected = open ? Target.pagePlay : game.map { Target.game($0.id) }
    }
    public func openRecent(_ id: String) {
        guard let recent = model.recentGames.first(where: { $0.id == id }) else { return }
        model.destination = .cloud
        model.openGame(recent.game)
        gamePageChanged(open: true)
    }

    public var launching = false { willSet { willChange?() } }
    public func play(_ game: Game) {
        if model.account == nil { model.loginOpen = true }
        else if !model.connectingCloud { launching = true; model.connectCloud(game: game) }
    }
    public func cancelLaunch() { model.cancelCloud(); launching = false }
    public func connectingChanged(_ connecting: Bool) {
        if connecting, model.cloudLaunchingGame != nil { launching = true }
    }

    public func move(_ offset: Int) {
        let games = games
        let limit = min(games.count, visibleCount)
        guard limit > 0 else { return }
        guard let chosen = model.selectedGame, let found = games.firstIndex(where: { $0.id == chosen.id }) else {
            model.showGame(games[0])
            focus.selected = Target.game(games[0].id)
            return
        }
        let index = min(limit - 1, found)
        if index + offset >= limit, limit < games.count {
            focus.selected = Target.more
            return
        }
        let next = min(limit - 1, max(0, index + offset))
        model.showGame(games[next])
        let target = Target.game(games[next].id)
        if focus.selected != target { focus.selected = target }
    }

    public func openChosen() { if let chosen = model.selectedGame { model.openGame(chosen) } else { move(0) } }

    public private(set) var fromGamepad = false
    public func gamepad(_ action: LibraryControllerAction) {
        fromGamepad = true
        handle(action)
        fromGamepad = false
    }

    public func typeSearch() {
        focus.openKeyboard(text: model.search, write: { [model] in model.search = $0 }) { [weak self] done in
            guard let self, done, let first = self.games.first else { return }
            self.model.showGame(first)
            self.focus.selected = Target.game(first.id)
        }
    }

    public func handle(_ action: LibraryControllerAction) {
        guard !model.loginOpen, !model.streamHasControls else { return }
        if focus.keyboard != nil { _ = focus.handle(action); return }
        if action == .erase { return }
        if !focus.choices.isEmpty { _ = focus.handle(action); return }
        if action == .back {
            if launching { cancelLaunch() }
            else if model.settingsOpen { model.settingsOpen = false }
            else if model.gameOpen { model.gameOpen = false }
            return
        }
        if launching { launchPress(action); return }
        if action == .settings { model.showSettings(); return }
        if focus.selected == nil {
            focus.selected = model.settingsOpen ? Target.settingsTab(model.settingsSection) : gamePageOpen ? Target.pagePlay : game.map { Target.game($0.id) }
        }
        if gamePageOpen, !model.settingsOpen {
            if action == .favorite { if let game { model.toggleFavorite(game.id) } } else { _ = focus.handle(action) }
            return
        }
        if !model.settingsOpen, model.destination == .cloud, focus.selected?.hasPrefix(Target.gamePrefix) == true {
            let index = games.firstIndex { $0.id == game?.id } ?? 0
            if action == .up, index < columns { focus.selected = Target.filter(model.filter); return }
            inGrid(action)
            return
        }
        if focus.handle(action) {
            if !model.settingsOpen, let id = focus.selected, id.hasPrefix(Target.gamePrefix),
               let selected = games.first(where: { Target.game($0.id) == id }), selected.id != model.selectedGame?.id {
                model.showGame(selected)
            }
            return
        }
        guard !model.settingsOpen, model.destination == .cloud else { return }
        inGrid(action)
    }

    private func launchPress(_ action: LibraryControllerAction) {
        focus.selected = Target.launchCancel
        switch action {
        case .left, .right, .up, .down: break
        case .play where !focus.places.contains(where: { $0.id == Target.launchCancel }): cancelLaunch()
        default: _ = focus.handle(action)
        }
    }

    private func inGrid(_ action: LibraryControllerAction) {
        switch action {
        case .left: move(-1)
        case .right: move(1)
        case .up: move(-columns)
        case .down: move(columns)
        case .play: openChosen()
        case .favorite: if let chosen = model.selectedGame { model.toggleFavorite(chosen.id) }
        case .back, .settings, .erase: break
        }
    }

    public func key(_ key: UInt16?, text: String) -> Bool {
        if model.streamHasControls || model.loginOpen { return false }
        if focus.selected != nil || model.settingsOpen || model.gameOpen {
            let actions: [UInt16: LibraryControllerAction] = [Key.left: .left, Key.right: .right, Key.down: .down, Key.up: .up, Key.enter: .play, Key.escape: .back]
            if let key, let action = actions[key] { handle(action); return true }
        }
        if key == Key.escape {
            if model.settingsOpen { model.settingsOpen = false; return true }
            if launching { cancelLaunch(); return true }
            return false
        }
        guard !model.settingsOpen, !launching, model.destination == .cloud else { return false }
        if Self.favoriteLetters.contains(text.lowercased()), let chosen = model.selectedGame { model.toggleFavorite(chosen.id); return true }
        guard !model.gameOpen else { return false }
        let moves: [UInt16: Int] = [Key.left: -1, Key.right: 1, Key.down: columns, Key.up: -columns]
        if let key, let offset = moves[key] { move(offset); return true }
        if key == Key.enter { openChosen(); return true }
        return false
    }
}
