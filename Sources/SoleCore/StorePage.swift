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
}
