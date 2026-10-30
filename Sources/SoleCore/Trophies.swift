import Foundation

public struct TrophyCounts: Codable, Equatable, Sendable {
    public var platinum = 0, gold = 0, silver = 0, bronze = 0
    public var total: Int { platinum + gold + silver + bronze }
    public init(platinum: Int = 0, gold: Int = 0, silver: Int = 0, bronze: Int = 0) {
        self.platinum = platinum; self.gold = gold; self.silver = silver; self.bronze = bronze
    }
    init(_ value: Any?) {
        let object = value as? [String: Any] ?? [:]
        platinum = Trophies.integer(object["platinum"]) ?? 0; gold = Trophies.integer(object["gold"]) ?? 0
        silver = Trophies.integer(object["silver"]) ?? 0; bronze = Trophies.integer(object["bronze"]) ?? 0
    }
}

public struct TrophySummary: Codable, Equatable, Sendable {
    public let level: Int
    public let progress: Int
    public let tier: Int
    public let earned: TrophyCounts
    public init(level: Int, progress: Int, tier: Int, earned: TrophyCounts) {
        self.level = level; self.progress = progress; self.tier = tier; self.earned = earned
    }

    public static func decode(_ data: Data) -> TrophySummary? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let level = Trophies.integer(object["trophyLevel"]), level >= 0 else { return nil }
        return TrophySummary(level: level, progress: min(100, max(0, Trophies.integer(object["progress"]) ?? 0)),
                             tier: Trophies.integer(object["tier"]) ?? 0, earned: TrophyCounts(object["earnedTrophies"]))
    }
}

public struct TrophyTitle: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let platform: String
    public let iconURL: URL?
    public let progress: Int
    public let earned: TrophyCounts
    public let defined: TrophyCounts
    public let updated: Date?
    public let service: String?
    public init(id: String, name: String, platform: String, iconURL: URL?, progress: Int, earned: TrophyCounts, defined: TrophyCounts, updated: Date?, service: String? = nil) {
        self.id = id; self.name = name; self.platform = platform; self.iconURL = iconURL
        self.progress = progress; self.earned = earned; self.defined = defined; self.updated = updated; self.service = service
    }
    public var serviceName: String {
        if let service, ["trophy", "trophy2"].contains(service) { return service }
        return platform.contains("PS5") ? "trophy2" : "trophy"
    }

    public static func list(_ data: Data) -> [TrophyTitle] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = object["trophyTitles"] as? [[String: Any]] else { return [] }
        let titles = rows.compactMap { row -> TrophyTitle? in
            guard let id = row["npCommunicationId"] as? String, !id.isEmpty,
                  let name = (row["trophyTitleName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
            return TrophyTitle(id: id, name: name, platform: row["trophyTitlePlatform"] as? String ?? "",
                               iconURL: (row["trophyTitleIconUrl"] as? String).flatMap(Trophies.pictureURL),
                               progress: min(100, max(0, Trophies.integer(row["progress"]) ?? 0)),
                               earned: TrophyCounts(row["earnedTrophies"]), defined: TrophyCounts(row["definedTrophies"]),
                               updated: PSNTime.date(row["lastUpdatedDateTime"] as? String), service: row["npServiceName"] as? String)
        }
        return titles.newestFirst(by: \.updated)
    }
}

extension Sequence {
    public func newestFirst(by date: (Element) -> Date?) -> [Element] {
        enumerated().sorted { a, b in
            switch (date(a.element), date(b.element)) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }
}

public struct AccountTrophies: Codable, Equatable, Sendable {
    public let summary: TrophySummary
    public let titles: [TrophyTitle]
    public init(summary: TrophySummary, titles: [TrophyTitle]) { self.summary = summary; self.titles = titles }
}

public struct TrophyDefinition: Equatable, Sendable {
    public let id: Int
    public let name: String
    public let detail: String
    public let grade: String
    public let iconURL: URL?
    public init(id: Int, name: String, detail: String, grade: String, iconURL: URL?) {
        self.id = id; self.name = name; self.detail = detail; self.grade = grade; self.iconURL = iconURL
    }
    public static func list(_ data: Data) -> [TrophyDefinition] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = object["trophies"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = Trophies.integer(row["trophyId"]) else { return nil }
            return TrophyDefinition(id: id, name: (row["trophyName"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                    detail: (row["trophyDetail"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                    grade: (row["trophyType"] as? String ?? "bronze").lowercased(),
                                    iconURL: (row["trophyIconUrl"] as? String).flatMap(Trophies.pictureURL))
        }
    }
}

public struct EarnedTrophy: Equatable, Sendable {
    public let id: Int
    public let earned: Bool
    public let date: Date?
    public init(id: Int, earned: Bool, date: Date?) { self.id = id; self.earned = earned; self.date = date }
    public static func list(_ data: Data) -> [EarnedTrophy] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = object["trophies"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = Trophies.integer(row["trophyId"]) else { return nil }
            return EarnedTrophy(id: id, earned: row["earned"] as? Bool ?? false, date: PSNTime.date(row["earnedDateTime"] as? String))
        }
    }
}

public struct TrophyNotice: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let detail: String
    public let grade: String
    public let iconURL: URL?
    public let game: String
    public init(id: String, name: String, detail: String, grade: String, iconURL: URL?, game: String) {
        self.id = id; self.name = name; self.detail = detail; self.grade = grade; self.iconURL = iconURL; self.game = game
    }
}

public struct TrophyWatch: Sendable {
    public let since: Date
    private var counts: [String: Int]?
    private var shown: Set<String> = []
    public init(since: Date) { self.since = since }

    public mutating func grown(_ titles: [TrophyTitle]) -> [TrophyTitle] {
        let now = Dictionary(titles.map { ($0.id, $0.earned.total) }, uniquingKeysWith: max)
        guard let before = counts else { counts = now; return [] }
        let grown = titles.filter { title in
            let earlier = before[title.id] ?? (title.updated.map { $0 >= since.addingTimeInterval(-60) } == true ? 0 : title.earned.total)
            return title.earned.total > earlier
        }
        counts = before.merging(now) { _, new in new }
        return grown
    }

    public mutating func notices(_ title: TrophyTitle, earned: [EarnedTrophy], defined: [TrophyDefinition]) -> [TrophyNotice] {
        let names = Dictionary(defined.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let fresh = earned.filter { $0.earned && ($0.date.map { $0 >= since.addingTimeInterval(-60) } ?? false) }
            .sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
        var notices: [TrophyNotice] = []
        for trophy in fresh {
            let id = "\(title.id)#\(trophy.id)"
            guard shown.insert(id).inserted else { continue }
            let definition = names[trophy.id]
            notices.append(TrophyNotice(id: id, name: definition?.name ?? "", detail: definition?.detail ?? "", grade: definition?.grade ?? "bronze",
                                        iconURL: definition?.iconURL ?? title.iconURL, game: title.name))
        }
        return notices
    }
}

enum Trophies {
    static func integer(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber where number !== NSNumber(value: true) && number !== NSNumber(value: false):
            let value = number.doubleValue
            guard value.isFinite, value.rounded(.towardZero) == value else { return nil }
            return Int(exactly: value)
        case let text as String: return Int(text)
        default: return nil
        }
    }
    static func pictureURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme == "https", url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }
        return url
    }
}
