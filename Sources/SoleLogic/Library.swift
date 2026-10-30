import Foundation
import SoleCloud
import SoleCore

public enum Library {
    public static func backend(platform: String) -> CloudBackend {
        let platform = platform.uppercased()
        if platform.contains("PS3") { return .ps3 }
        if platform.contains("PS4"), !platform.contains("PS5") { return .psPlusPC }
        return .ps5
    }
    public static func games(history titles: [PlayedTitle], favorites: Set<String>) -> [Game] {
        var seen = Set<String>()
        return titles.map { title in
            let id = historyID(title)
            return Game(id: id, title: title.displayName, platform: title.platform, favorite: favorites.contains(id) || favorites.contains(title.id),
                        artworkURL: title.artworkURL, conceptID: title.concept?.id, cloudBackend: backend(platform: title.platform))
        }.filter { seen.insert($0.id).inserted }
    }
    public static func historyID(_ title: PlayedTitle) -> String { title.concept.map { "concept:\($0.id)" } ?? title.id }
    public static func game(_ title: CloudTitle, favorites: Set<String>, platform: String? = nil) -> Game {
        Game(id: title.id, title: title.name, platform: platform ?? (title.device ?? ["PS5"]).joined(separator: " · "), favorite: favorites.contains(title.id),
             artworkURL: title.artworkURL, conceptID: title.conceptId, productID: title.productId, genres: title.genre ?? [])
    }
    public static func game(_ title: PSPlusPCService.Title, favorites: Set<String>) -> Game {
        let id = "pc:" + title.productID
        return Game(id: id, title: title.name, platform: title.backend.console, favorite: favorites.contains(id), artworkURL: title.artworkURL,
                    productID: title.productID, cloudBackend: title.backend)
    }
    public static func catalog(_ catalog: [Game], replacingStreamed titles: [PSPlusPCService.Title], favorites: Set<String>) -> [Game] {
        (catalog.filter { $0.cloudBackend == .ps5 } + titles.map { game($0, favorites: favorites) })
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    public static func streamingCandidates(_ unconfirmed: [CloudTitle], owned: OwnedLibrary, history: [Game], query: String) -> [CloudTitle] {
        let recent = Set(history.map { OwnedLibrary.normalizedName($0.title) })
        func named(_ title: CloudTitle) -> Bool { !query.isEmpty && title.name.localizedCaseInsensitiveContains(query) }
        return unconfirmed.filter {
            owned.contains(productID: $0.productId, conceptID: $0.conceptId, title: $0.name) || recent.contains(OwnedLibrary.normalizedName($0.name)) || named($0)
        }.sorted { a, b in
            let first = named(a), second = named(b)
            return first != second ? first : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    public static func filters(for backend: CloudBackend) -> [LibraryFilter] {
        backend == .ps3 ? [.all, .favorites] : LibraryFilter.allCases
    }
    public static func filter(saved: String?, backend: String?) -> LibraryFilter {
        let saved = saved.flatMap(LibraryFilter.init(rawValue:)) ?? .all
        return filters(for: backend.flatMap(CloudBackend.init(rawValue:)) ?? .ps5).contains(saved) ? saved : .all
    }
    public static func listed(_ filter: LibraryFilter, backend: CloudBackend, search: String, catalog: [Game], history: [Game], isOwned: (Game) -> Bool) -> [Game] {
        let source = filter == .recent ? recent(history, in: catalog, backend: backend) : filter == .favorites ? favorites(catalog: catalog, history: history) : catalog
        return source.filter { game in
            game.cloudBackend == backend && (search.isEmpty || game.title.localizedCaseInsensitiveContains(search)) &&
            (filter != .favorites || game.favorite) && (filter != .owned || isOwned(game))
        }
    }
    public static func ordered(_ games: [Game], filter: LibraryFilter, search: String) -> [Game] {
        guard filter == .all, search.isEmpty else { return games }
        let names = ["demon’s souls", "demon's souls", "mortal kombat", "cyberpunk 2077", "valhalla", "fortnite"]
        let featured = names.compactMap { name in games.first { $0.title.lowercased().contains(name) } }
        var seen = Set<String>()
        return (featured + games).filter { seen.insert($0.id).inserted }
    }
    public static func recent(_ history: [Game], in catalog: [Game], backend: CloudBackend) -> [Game] {
        var streamed: [String: Game] = [:], mine: [String: Game] = [:]
        for game in catalog where game.cloudBackend != .ps5 {
            let name = OwnedLibrary.normalizedName(game.title)
            if streamed[name] == nil { streamed[name] = game }
            if game.cloudBackend == backend, mine[name] == nil { mine[name] = game }
        }
        var seen = Set<String>()
        return history.compactMap { game -> Game? in
            let name = OwnedLibrary.normalizedName(game.title)
            let unknown = game.platform == "PlayStation"
            if backend == .ps5 { return game.cloudBackend == .ps5 && !(unknown && streamed[name] != nil) ? game : nil }
            guard game.cloudBackend == backend || unknown, let match = mine[name], seen.insert(match.id).inserted else { return nil }
            return match
        }
    }
    public static func favorites(catalog: [Game], history: [Game]) -> [Game] {
        var seen = Set<String>()
        return (catalog + history).filter { $0.favorite && seen.insert($0.id).inserted }
    }

    public struct ClaimedNames: Sendable {
        public let ps5: Set<String>
        public let other: Set<String>
        public init(_ owned: OwnedLibrary, catalog: [Game]) {
            let products = catalog.compactMap(\.productID)
            ps5 = owned.claimedNames(by: products, ps5: true); other = owned.claimedNames(by: products, ps5: false)
        }
    }
    public static func isOwned(_ game: Game, by owned: OwnedLibrary, claimed: ClaimedNames) -> Bool {
        let ps5 = game.cloudBackend == .ps5
        return owned.contains(productID: game.productID, conceptID: game.conceptID, title: game.title, claimed: ps5 ? claimed.ps5 : claimed.other, ps5: ps5)
    }

    public static func startable(_ chosen: Game, in catalog: [Game]) -> Game {
        catalog.first(where: { $0.cloudBackend == chosen.cloudBackend && ($0.id == chosen.id || (chosen.conceptID != nil && $0.conceptID == chosen.conceptID)) })
            ?? (chosen.cloudBackend != .ps5 ? catalog.first(where: { $0.cloudBackend == chosen.cloudBackend && sameName($0, chosen) }) : nil)
            ?? chosen
    }
    public static func canStart(_ game: Game) -> Bool { game.productID != nil || game.conceptID != nil }
    public static func page(for game: Game, in catalog: [Game]) -> Game {
        guard game.cloudBackend != .ps5 else { return game }
        return catalog.first(where: { $0.cloudBackend == game.cloudBackend && ($0.id == game.id || sameName($0, game)) }) ?? game
    }
    public static func elsewhere(_ game: Game, in catalog: [Game]) -> Game? {
        catalog.first(where: { $0.cloudBackend != game.cloudBackend && $0.cloudBackend != .ps5 && sameName($0, game) })
    }
    private static func sameName(_ a: Game, _ b: Game) -> Bool { OwnedLibrary.normalizedName(a.title) == OwnedLibrary.normalizedName(b.title) }
}

public enum CatalogRegion {
    public static var choices: [(String, String)] {
        [("en-us", loc("United States")), ("en-gb", loc("United Kingdom")), ("de-de", loc("Germany")), ("fr-fr", loc("France")), ("ja-jp", loc("Japan")), ("es-es", loc("Spain")), ("it-it", loc("Italy")), ("pl-pl", loc("Poland"))]
    }
}

public extension Datacenter {
    static func name(_ id: String, among ids: [String]) -> String { localizedCity(CloudDatacenterName.display(id, among: ids)) }
}
