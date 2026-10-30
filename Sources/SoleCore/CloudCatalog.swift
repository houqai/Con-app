import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CloudTitle: Decodable, Identifiable, Sendable {
    public let conceptId: Int
    public let name: String
    public let imageUrl: String?
    public let productId: String?
    public let genre: [String]?
    public let device: [String]?
    public let streamingSupported: Bool?
    public var id: String { "concept:\(conceptId)" }
    public var artworkURL: URL? {
        guard let imageUrl, let url = URL(string: imageUrl), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
    public var storeURL: URL { CloudCatalog.storeURL(conceptID: conceptId) }
}

public enum CloudCatalog {
    public static func storeURL(conceptID: Int) -> URL { URL(string: "https://store.playstation.com/concept/\(conceptID)")! }
    private struct Group: Decodable { let games: [CloudTitle] }
    public static func decode(_ data: Data) throws -> [CloudTitle] {
        try parse(data).titles
    }
    static func parse(_ data: Data) throws -> (titles: [CloudTitle], unconfirmed: [CloudTitle]) {
        let games = try JSONDecoder().decode([Group].self, from: data).flatMap(\.games)
        var seenConfirmed = Set<Int>(), seenUnconfirmed = Set<Int>()
        let titles = games.filter { game in
            game.streamingSupported == true
                && game.conceptId > 0
                && !game.name.isEmpty
                && seenConfirmed.insert(game.conceptId).inserted
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let unconfirmed = games.filter { game in
            game.streamingSupported != true
                && game.conceptId > 0
                && !game.name.isEmpty
                && game.device?.contains("PS5") == true
                && seenUnconfirmed.insert(game.conceptId).inserted
        }
        return (titles, unconfirmed)
    }
    public static func endpoint(locale: String) -> URL? {
        guard supportedLocales.contains(locale) else { return nil }
        var url = URLComponents(string: "https://www.playstation.com/bin/imagic/gameslist")!
        url.queryItems = [.init(name: "locale", value: locale), .init(name: "categoryList", value: "all-ps5-list")]
        return url.url
    }
    public static let supportedLocales = ["en-us", "en-gb", "de-de", "fr-fr", "ja-jp", "es-es", "it-it", "pl-pl"]
}

public actor CloudCatalogService {
    public struct Result: Sendable {
        public let titles: [CloudTitle]
        public let unconfirmed: [CloudTitle]
    }
    public enum Failure: Error { case unsupportedLocale, server(Int), invalidResponse }
    private let session: URLSession
    private let cacheDirectory: URL?
    public init(cacheDirectory: URL? = nil) {
        self.cacheDirectory = cacheDirectory
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 25
        session = .lasting(configuration)
    }
    private struct Cache: Codable {
        let locale: String
        let updatedAt: Date
        let data: Data
    }
    private func cacheURL(_ locale: String) -> URL? { cacheDirectory?.appendingPathComponent("catalog-\(locale).json") }
    public func load(locale: String, force: Bool = false) async throws -> Result {
        guard let url = CloudCatalog.endpoint(locale: locale) else { throw Failure.unsupportedLocale }
        var cached: Result?
        if let file = cacheURL(locale), let data = try? Data(contentsOf: file),
           let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.locale == locale,
           let parsed = try? CloudCatalog.parse(cache.data) {
            let age = Date().timeIntervalSince(cache.updatedAt)
            let result = Result(titles: parsed.titles, unconfirmed: parsed.unconfirmed)
            cached = result
            if !force, age >= 0, age < 86400 { return result }
        }
        do {
            let (data, response) = try await session.plainData(from: url)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw Failure.invalidResponse }
            guard (200..<300).contains(response.statusCode) else { throw Failure.server(response.statusCode) }
            guard data.count <= 20_000_000 else { throw Failure.invalidResponse }
            let parsed = try CloudCatalog.parse(data)
            guard !parsed.titles.isEmpty else { throw Failure.invalidResponse }
            let date = Date()
            if let file = cacheURL(locale), let cacheDirectory {
                try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
                if let encoded = try? JSONEncoder().encode(Cache(locale: locale, updatedAt: date, data: data)) {
                    try? encoded.write(to: file, options: .atomic)
                }
            }
            return Result(titles: parsed.titles, unconfirmed: parsed.unconfirmed)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if let cached { return cached }
            throw error
        }
    }
}
