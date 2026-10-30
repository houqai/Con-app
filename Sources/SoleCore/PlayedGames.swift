import Foundation

public struct PlayedGamesPage: Decodable {
    public let titles: [PlayedTitle]
    public let nextOffset: Int?
}

public struct PlayedTitle: Decodable, Identifiable {
    public struct Concept: Decodable { public let id: Int }
    private enum CodingKeys: String, CodingKey { case concept, titleId, name, localizedName, category, imageUrl, localizedImageUrl, lastPlayedDateTime }
    public let concept: Concept?
    public let titleId: String
    public let name: String
    public let localizedName: String?
    public let category: String?
    public let imageUrl: String?
    public let localizedImageUrl: String?
    public let lastPlayedDateTime: String?
    public let lastPlayed: Date?
    public var id: String { titleId }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        concept = try container.decodeIfPresent(Concept.self, forKey: .concept)
        titleId = try container.decode(String.self, forKey: .titleId)
        name = try container.decode(String.self, forKey: .name)
        localizedName = try container.decodeIfPresent(String.self, forKey: .localizedName)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        imageUrl = try container.decodeIfPresent(String.self, forKey: .imageUrl)
        localizedImageUrl = try container.decodeIfPresent(String.self, forKey: .localizedImageUrl)
        lastPlayedDateTime = try container.decodeIfPresent(String.self, forKey: .lastPlayedDateTime)
        lastPlayed = PSNTime.date(lastPlayedDateTime)
    }
    public var displayName: String {
        if let localizedName, !localizedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return localizedName }
        return name
    }
    public var platform: String {
        switch category {
        case "ps4_game": return "PS4"
        case "ps5_native_game": return "PS5"
        case "pspc_game": return "PC"
        default: return "PlayStation"
        }
    }
    public var artworkURL: URL? {
        for candidate in [localizedImageUrl, imageUrl] {
            if let candidate, let url = URL(string: candidate), url.scheme == "https", url.host != nil,
               url.user == nil, url.password == nil { return url }
        }
        return nil
    }
}

public enum PSNTime {
    private static let lock = NSLock()
    private static let plain = ISO8601DateFormatter()
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    public static func date(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return lock.withLock { plain.date(from: text) ?? fractional.date(from: text) }
    }
}
