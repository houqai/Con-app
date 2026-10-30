import Foundation
import SoleCore

public struct AccountPage {
    public enum Grade: CaseIterable, Sendable {
        case platinum, gold, silver, bronze
        public init(_ name: String) {
            switch name.lowercased() {
            case "platinum": self = .platinum
            case "gold": self = .gold
            case "silver": self = .silver
            default: self = .bronze
            }
        }
        public var title: String {
            switch self {
            case .platinum: return loc("Platinum")
            case .gold: return loc("Gold")
            case .silver: return loc("Silver")
            case .bronze: return loc("Bronze")
            }
        }
        public var color: (red: Double, green: Double, blue: Double) {
            switch self {
            case .platinum: return (0.80, 0.86, 0.96)
            case .gold: return (0.96, 0.78, 0.33)
            case .silver: return (0.76, 0.79, 0.84)
            case .bronze: return (0.82, 0.55, 0.36)
            }
        }
        public func count(_ counts: TrophyCounts) -> Int {
            switch self {
            case .platinum: return counts.platinum
            case .gold: return counts.gold
            case .silver: return counts.silver
            case .bronze: return counts.bronze
            }
        }
    }
    public enum TrophyFailure: Sendable, Equatable {
        case refused
        case failed
    }
    public struct RecentGame: Identifiable, Sendable {
        public let game: Game
        public let lastPlayed: Date?
        public var id: String { game.id }
    }

    public static let recentCount = 10, trophyTitlesCount = 4

    public let shown: Bool
    public let trophies: AccountTrophies?
    public let trophyNote: String?
    public let recent: [RecentGame]
    public let recentNote: String?
    private let now: Date

    @MainActor public init(_ model: AppModel, now: Date = Date()) {
        self.now = now
        shown = model.account != nil
        trophies = model.trophies
        switch (model.trophies, model.trophiesFailure) {
        case (nil, _) where model.loadingTrophies: trophyNote = loc("Loading trophies…")
        case (_, .refused?): trophyNote = loc("Sony does not show trophies for this sign-in.")
        case (nil, .failed?): trophyNote = loc("Could not load trophies.")
        case (nil, nil): trophyNote = loc("No trophies yet.")
        default: trophyNote = nil
        }
        recent = model.recentGames
        if !model.recentGames.isEmpty {
            recentNote = nil
        } else if model.loadingLibrary {
            recentNote = loc("Loading recent games…")
        } else if model.libraryError != nil {
            recentNote = loc("Could not load recent games. Try refreshing the library.")
        } else {
            recentNote = loc("No recent games yet.")
        }
    }

    public var levelText: String? { trophies.map { loc("Level %@", $0.summary.level) } }
    public var progressText: String? { trophies.map { loc("%@% to level %@", $0.summary.progress, $0.summary.level + 1) } }
    public var grades: [(grade: Grade, count: Int)] {
        guard let earned = trophies?.summary.earned else { return [] }
        return Grade.allCases.map { ($0, $0.count(earned)) }
    }
    public var trophyTitles: [TrophyTitle] { Array((trophies?.titles ?? []).prefix(Self.trophyTitlesCount)) }
    public static func trophyTitleNote(_ title: TrophyTitle) -> String {
        let platform = title.platform.replacingOccurrences(of: ",", with: " · ")
        let earned = loc("%@ of %@", title.earned.total, title.defined.total)
        return platform.isEmpty ? earned : platform + " · " + earned
    }
    public func lastPlayedText(_ game: RecentGame) -> String? { Self.lastPlayedText(game.lastPlayed, now: now) }
    public static func lastPlayedText(_ date: Date?, now: Date, calendar: Calendar = .current) -> String? {
        guard let date else { return nil }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1: return loc("Today")
        case 1: return loc("Yesterday")
        case 2..<30: return loc("%@ days ago", days)
        default:
            let parts = calendar.dateComponents([.day, .month, .year], from: date)
            return String(format: "%02d.%02d.%04d", parts.day ?? 0, parts.month ?? 0, parts.year ?? 0)
        }
    }

    public static func recent(_ titles: [PlayedTitle], favorites: Set<String>, limit: Int = recentCount) -> [RecentGame] {
        let ordered = titles.newestFirst(by: \.lastPlayed)
        var dates: [String: Date] = [:]
        for title in ordered { let id = Library.historyID(title); if dates[id] == nil { dates[id] = title.lastPlayed } }
        return Library.games(history: ordered, favorites: favorites).prefix(limit).map { RecentGame(game: $0, lastPlayed: dates[$0.id]) }
    }

    static func diagnostics(summaryStatus: Int, titlesStatus: Int?, read: Bool) -> [String: Any] {
        var record: [String: Any] = ["trophySummary": summaryStatus, "read": read]
        if let titlesStatus { record["trophyTitles"] = titlesStatus }
        return record
    }
    nonisolated static func recordDiagnostics(summaryStatus: Int, titlesStatus: Int?, read: Bool) {
        Diagnostics.write(diagnostics(summaryStatus: summaryStatus, titlesStatus: titlesStatus, read: read), named: "trophies.json")
    }
}

extension TrophyNotice {
    public var heading: String { loc("Trophy earned") + " · " + AccountPage.Grade(grade).title }
    public var title: String { name.isEmpty ? game : name }
}
