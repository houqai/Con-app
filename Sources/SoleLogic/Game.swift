import Foundation
import SoleCloud
import SoleCore

public struct Game: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let platform: String
    public var favorite: Bool
    public let artworkURL: URL?
    public var conceptID: Int?
    public var productID: String?
    public var genres: [String]
    public var cloudBackend: CloudBackend
    public var storeURL: URL? { conceptID.map(CloudCatalog.storeURL(conceptID:)) }
    public init(id: String, title: String, platform: String, favorite: Bool, artworkURL: URL?, conceptID: Int? = nil, productID: String? = nil,
                genres: [String] = [], cloudBackend: CloudBackend = .ps5) {
        self.id = id; self.title = title; self.platform = platform; self.favorite = favorite; self.artworkURL = artworkURL
        self.conceptID = conceptID; self.productID = productID; self.genres = genres; self.cloudBackend = cloudBackend
    }
}

public extension CloudBackend {
    var console: String { self == .ps3 ? "PS3" : self == .psPlusPC ? "PS4" : "PS5" }
}

public enum Destination: String, CaseIterable, Sendable { case cloud = "Cloud", consoles = "Consoles" }

public extension Destination {
    static let consolesShown = false
}

public enum LibraryFilter: String, CaseIterable, Sendable { case all = "All games", owned = "Purchased", recent = "Recent", favorites = "Favorites" }

public struct Account: Sendable {
    public let displayName: String
    public var avatarURL: URL?
    public var isPlus: Bool?
    public init(_ profile: PSNProfile) { displayName = profile.onlineID; avatarURL = profile.avatarURL; isPlus = profile.isPlus }
}

public struct Datacenter: Identifiable, Codable, Sendable {
    public let id: String
    public let latency: Int?
    public init(id: String, latency: Int?) { self.id = id; self.latency = latency }
}
