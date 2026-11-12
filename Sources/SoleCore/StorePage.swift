import Foundation

public enum StorePage {
    public static func endpoint(conceptID: Int, locale: String) -> URL? {
        guard conceptID > 0, CloudCatalog.supportedLocales.contains(locale) else { return nil }
        return URL(string: "https://store.playstation.com/\(locale)/concept/\(conceptID)")
    }

    public static func caches(in html: Data) -> [[String: Any]] {
        let page = String(decoding: html, as: UTF8.self)
        var caches: [[String: Any]] = []
        var cursor = page.startIndex
        while let open = page.range(of: "type=\"application/json\">", range: cursor..<page.endIndex),
              let close = page.range(of: "</script>", range: open.upperBound..<page.endIndex) {
            cursor = close.upperBound
            guard let object = (try? JSONSerialization.jsonObject(with: Data(page[open.upperBound..<close.lowerBound].utf8))) as? [String: Any],
                  let cache = object["cache"] as? [String: Any] else { continue }
            caches.append(cache)
        }
        return caches
    }

    public static func ps5FullGame(_ html: Data, conceptID: Int) -> String? {
        var concepts: [[String: Any]] = []
        var products: [String: [String: Any]] = [:]
        for cache in caches(in: html) {
            for (key, value) in cache {
                guard let object = value as? [String: Any] else { continue }
                if key == "Concept:\(conceptID)" { concepts.append(object) }
                if key.hasPrefix("Product:"), let id = object["id"] as? String { products[id] = object }
            }
        }
        let listed = concepts.flatMap { $0["products"] as? [[String: Any]] ?? [] }.compactMap { ref -> (String, String)? in
            guard let key = ref["__ref"] as? String, let id = key.split(separator: ":", maxSplits: 1).last.map(String.init),
                  let product = products[id], id.contains("-PPSA"),
                  (product["platforms"] as? [String])?.contains("PS5") == true,
                  let kind = product["storeDisplayClassification"] as? String else { return nil }
            return (id, kind)
        }
        if let full = listed.first(where: { $0.1 == "FULL_GAME" }) { return full.0 }
        for concept in concepts {
            guard let key = (concept["defaultProduct"] as? [String: Any])?["__ref"] as? String,
                  let id = key.split(separator: ":", maxSplits: 1).last.map(String.init), id.contains("-PPSA") else { continue }
            return id
        }
        return listed.first?.0
    }
}
