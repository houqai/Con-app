import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum StoreScreenshots {
    public static func parse(_ html: Data, conceptID: Int) -> [URL] {
        var result: [URL] = [], seen = Set<String>()
        for cache in StorePage.caches(in: html) {
            guard let concept = cache["Concept:\(conceptID)"] as? [String: Any] else { continue }
            var entities = [concept]
            if let ref = (concept["defaultProduct"] as? [String: Any])?["__ref"] as? String,
               let product = cache[ref] as? [String: Any] { entities.append(product) }
            for entity in entities {
                let media = (entity["media"] as? [[String: Any]] ?? []) + ((entity["personalizedMeta"] as? [String: Any])?["media"] as? [[String: Any]] ?? [])
                for item in media {
                    guard item["type"] as? String == "IMAGE", item["role"] as? String == "SCREENSHOT",
                          let text = item["url"] as? String, let url = URL(string: text), url.scheme == "https",
                          let host = url.host, host == "playstation.com" || host.hasSuffix(".playstation.com") || host.hasSuffix(".playstation.net"),
                          url.user == nil, url.password == nil, seen.insert(text).inserted else { continue }
                    result.append(url)
                }
            }
        }
        return Array(result.prefix(6))
    }
}

public actor StoreScreenshotService {
    private static let http = URLSession.lasting(.ephemeral)
    private var cache: [String: [URL]] = [:]
    public init() {}
    public func screenshots(conceptID: Int, locale: String) async throws -> [URL] {
        let key = "\(locale)|\(conceptID)"
        if let result = cache[key] { return result }
        guard let url = StorePage.endpoint(conceptID: conceptID, locale: locale) else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await Self.http.plainData(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), data.count <= 8_000_000 else { return [] }
        let result = StoreScreenshots.parse(data, conceptID: conceptID)
        cache[key] = result
        return result
    }
}
