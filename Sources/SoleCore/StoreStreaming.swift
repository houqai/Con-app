import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum StoreStreaming {
    public static func supportsPS5(_ html: Data, conceptID: Int, productID: String) -> Bool {
        StorePage.caches(in: html).contains { cache in
            guard cache["Concept:\(conceptID)"] != nil,
                  let product = cache["Product:\(productID)"] as? [String: Any],
                  (product["platforms"] as? [String])?.contains("PS5") == true,
                  let notices = product["compatibilityNoticesByPlatform"] as? [String: Any] else { return false }
            let rows = ["Common", "PS5"].flatMap { notices[$0] as? [[String: Any]] ?? [] }
            return rows.contains(where: offersPS5Streaming)
        }
    }
    private static func offersPS5Streaming(_ row: [String: Any]) -> Bool {
        row["type"] as? String == "STREAMING_SUPPORTED"
            && row["value"] as? String == "OPTIONAL"
            && (row["targetPlatforms"] as? [String] ?? []).contains("PS5")
    }
}

public actor StoreStreamingService {
    private static let http = URLSession.lasting(.ephemeral)
    private var checked: [String: Bool] = [:]
    public init() {}
    public func supports(_ title: CloudTitle, locale: String) async throws -> Bool {
        guard let product = title.productId, product.contains("-PPSA"), let url = StorePage.endpoint(conceptID: title.conceptId, locale: locale) else { return false }
        let key = locale + "|" + product
        if let known = checked[key] { return known }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await Self.http.plainData(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, data.count < 8_000_000 else { return false }
        let result = StoreStreaming.supportsPS5(data, conceptID: title.conceptId, productID: product)
        checked[key] = result
        return result
    }
}
