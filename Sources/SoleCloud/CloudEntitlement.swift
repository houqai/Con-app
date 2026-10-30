import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SoleCore

public actor CloudEntitlementService {
    public enum Failure: Error { case unavailable, invalidResponse, service(Int), unsupportedProduct }
    public static let redirect = "https://psnow.playstation.com/app/2.2.0/133/5cdcc037d/grc-response.html"
    static let clientID = SonyClients.entitlements
    private let http: URLSession
    public init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 25
        http = session ?? .lasting(configuration, delegate: NoRedirects())
    }
    public static func authorizationURL(state: String, deviceID: String) throws -> URL {
        guard !state.isEmpty, deviceID.count == 48, deviceID.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw Failure.invalidResponse }
        var url = URLComponents(string: "https://ca.account.sony.com/api/authz/v3/oauth/authorize")!
        url.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect), .init(name: "response_type", value: "token"),
            .init(name: "scope", value: "kamaji:get_internal_entitlements"),
            .init(name: "state", value: state), .init(name: "duid", value: deviceID),
            .init(name: "prompt", value: "none"), .init(name: "smcid", value: "pc:psnow"),
            .init(name: "applicationId", value: "psnow"), .init(name: "service_entity", value: "urn:service-entity:psn")
        ]
        return url.url!
    }
    public static func token(from callback: URL, expectedState: String) throws -> String {
        guard let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host == "psnow.playstation.com", parts.port == nil,
              parts.user == nil, parts.password == nil,
              parts.path == URL(string: redirect)!.path, !expectedState.isEmpty else { throw CloudProtocol.Failure.invalidCallback }
        var fragmentParts = URLComponents()
        fragmentParts.percentEncodedQuery = parts.percentEncodedFragment
        let fragment = fragmentParts.queryItems ?? []
        let encoded = ((parts.percentEncodedQuery ?? "") + "&" + (parts.percentEncodedFragment ?? "")).uppercased()
        guard !encoded.contains("%0D"), !encoded.contains("%0A"), !encoded.contains("%00") else { throw CloudProtocol.Failure.invalidCallback }
        let fields = (parts.queryItems ?? []) + fragment
        guard fields.filter({ $0.name == "state" }).count == 1,
              fields.first(where: { $0.name == "state" })?.value == expectedState else { throw CloudProtocol.Failure.invalidCallback }
        if let value = fields.first(where: { $0.name == "error" })?.value {
            throw CloudProtocol.Failure.grant("Game licenses", CloudProtocol.safeProviderError(value) ?? "unknown")
        }
        let tokens = fields.filter { $0.name == "access_token" }
        guard tokens.count == 1, let token = tokens.first?.value, !token.isEmpty, token.count < 16_384,
              !token.contains("\r"), !token.contains("\n") else { throw CloudProtocol.Failure.invalidCallback }
        return token
    }
    public func resolve(productID: String?, conceptID: Int? = nil, title: String? = nil, token: String) async throws -> String {
        guard productID.map(Self.validID) == true || (productID == nil && (conceptID ?? 0) > 0) else { throw Failure.unsupportedProduct }
        var seen = Set<String>()
        var allRows: [[String: Any]] = []
        for page in 0..<100 {
            let rows = try await self.page(page, token: token)
            allRows.append(contentsOf: rows)
            if rows.count < 300 {
                let native = Self.nativeSelection(allRows, productID: productID, conceptID: conceptID, products: [])
                let related = native == nil ? try await storeEditions(conceptID: conceptID, productID: productID) : []
                guard let entitlement = Self.selection(allRows, productID: productID, conceptID: conceptID, products: related) else {
                    Self.recordMismatch(allRows, requested: productID, conceptID: conceptID, title: title)
                    throw Failure.unavailable
                }
                Self.recordSelection(allRows, id: entitlement, requested: productID ?? "concept:\(conceptID ?? 0)")
                return entitlement
            }
            let ids = Set(rows.compactMap { $0["id"] as? String })
            guard !ids.isEmpty, !ids.isSubset(of: seen) else { throw Failure.invalidResponse }
            seen.formUnion(ids)
        }
        throw Failure.invalidResponse
    }
    private func storeEditions(conceptID: Int?, productID: String?) async throws -> Set<String> {
        guard let conceptID, conceptID > 0 else { return [] }
        let url = URL(string: "https://store.playstation.com/en-us/concept/\(conceptID)")!
        do {
            let (data, response) = try await http.plainData(from: url)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200, data.count < 10_000_000 else { return [] }
            return Self.storeEditions(data, conceptID: conceptID, productID: productID)
        } catch {
            try Task.checkCancellation()
            return []
        }
    }
    static func storeEditions(_ data: Data, conceptID: Int, productID: String?) -> Set<String> {
        let page = String(decoding: data, as: UTF8.self)
        var cache: [String: [String: Any]] = [:]
        var cursor = page.startIndex
        while let open = page.range(of: "type=\"application/json\">", range: cursor..<page.endIndex),
              let close = page.range(of: "</script>", range: open.upperBound..<page.endIndex) {
            cursor = close.upperBound
            guard let object = try? JSONSerialization.jsonObject(with: Data(page[open.upperBound..<close.lowerBound].utf8)) as? [String: Any],
                  let entries = object["cache"] as? [String: [String: Any]] else { continue }
            for (key, value) in entries { cache[key, default: [:]].merge(value) { _, new in new } }
        }
        let conceptKey = "Concept:\(conceptID)"
        guard let concept = cache[conceptKey],
              let refs = concept["products"] as? [[String: Any]] else { return [] }
        let selected = productID.map { "Product:" + $0 } ?? (concept["defaultProduct"] as? [String: Any])?["__ref"] as? String
        guard let selected, refs.contains(where: { $0["__ref"] as? String == selected }),
              let name = cache[selected]?["name"] as? String else { return [] }
        func nameKey(_ name: String) -> String {
            name.lowercased().replacingOccurrences(of: "(playstation plus)", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func edition(_ longer: String, of shorter: String) -> Bool { longer.hasPrefix(shorter + " ") && longer.hasSuffix(" edition") }
        let wanted = nameKey(name), wantedTitle = titleID(String(selected.dropFirst("Product:".count)))
        return Set(refs.compactMap { ref -> String? in
            guard let key = ref["__ref"] as? String, let product = cache[key],
                  let id = product["id"] as? String, validID(id), id.contains("-PPSA"),
                  let title = product["name"] as? String,
                  ["FULL_GAME", "GAME_BUNDLE", "PREMIUM_EDITION"].contains(product["storeDisplayClassification"] as? String ?? ""),
                  (product["platforms"] as? [String])?.contains("PS5") == true else { return nil }
            let other = nameKey(title)
            guard other == wanted || (wantedTitle != nil && titleID(id) == wantedTitle && (edition(other, of: wanted) || edition(wanted, of: other))) else { return nil }
            return id
        })
    }
    static func titleID(_ productID: String) -> String? {
        let parts = productID.split(separator: "-", omittingEmptySubsequences: false)
        return parts.count == 3 && parts[1].count == 12 ? String(parts[1]) : nil
    }
    static func selectEdition(_ rows: [[String: Any]], products: Set<String>, nativeOnly: Bool = false) -> String? {
        let candidates = rows.filter { row in
            guard !nativeOnly || isNativePS5(row), let product = row["product_id"] as? String, products.contains(product),
                  row["active_flag"] as? Bool == true, isWholeGame(row),
                  launchIdentifier(row) != nil else { return false }
            return true
        }
        return preferredLicense(candidates).flatMap(launchIdentifier)
    }

    private func page(_ index: Int, token: String) async throws -> [[String: Any]] {
        try Task.checkCancellation()
        var url = URLComponents(string: "https://commerce.api.np.km.playstation.net/commerce/api/v1/users/me/internal_entitlements")!
        url.queryItems = [.init(name: "fields", value: "game_meta"), .init(name: "entitlement_type", value: "5"),
                          .init(name: "start", value: String(index * 300)), .init(name: "size", value: "300")]
        var request = URLRequest(url: url.url!)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await http.plainData(for: request)
        guard let response = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        guard response.statusCode == 200 else { throw Failure.service(response.statusCode) }
        guard data.count < 5_000_000 else { throw Failure.invalidResponse }
        return try Self.rows(data)
    }

    public struct OwnedTitle: Equatable, Sendable {
        public let productID: String
        public let licenseID: String?
        public let conceptID: Int?
        public let name: String?
        public init(productID: String, licenseID: String? = nil, conceptID: Int? = nil, name: String? = nil) { self.productID = productID; self.licenseID = licenseID; self.conceptID = conceptID; self.name = name }
    }

    public func owned(token: String, includePS4: Bool = false) async throws -> [OwnedTitle] {
        var seen = Set<String>()
        var titles: [OwnedTitle] = []
        for page in 0..<100 {
            let rows = try await self.page(page, token: token)
            titles.append(contentsOf: Self.owned(rows, includePS4: includePS4))
            if rows.count < 300 { return titles }
            let ids = Set(rows.compactMap { $0["id"] as? String })
            guard !ids.isEmpty, !ids.isSubset(of: seen) else { throw Failure.invalidResponse }
            seen.formUnion(ids)
        }
        throw Failure.invalidResponse
    }

    static func owned(_ rows: [[String: Any]], includePS4: Bool = false) -> [OwnedTitle] {
        rows.compactMap { row in
            guard row["active_flag"] as? Bool == true, let product = row["product_id"] as? String, validID(product),
                  launchIdentifier(row) != nil || (includePS4 && product.contains("-CUSA")) else { return nil }
            guard isWholeGame(row) else { return nil }
            let meta = row["game_meta"] as? [String: Any] ?? [:]
            let name = (meta["name"] as? String).flatMap { $0.isEmpty || $0.count > 200 ? nil : $0 }
            let license = (row["id"] as? String).flatMap { validID($0) && $0 != product ? $0 : nil }
            return OwnedTitle(productID: product, licenseID: license, conceptID: concept(of: row), name: name)
        }
    }
    private static func concept(of row: [String: Any]) -> Int? {
        let meta = row["game_meta"] as? [String: Any] ?? [:]
        return CloudAllocation.integer(row["conceptId"] ?? row["concept_id"] ?? meta["conceptId"] ?? meta["concept_id"])
    }

    private static func recordSelection(_ rows: [[String: Any]], id: String, requested: String) {
        guard let row = rows.first(where: { $0["id"] as? String == id || $0["product_id"] as? String == id }),
              let directory = Diagnostics.directory else { return }
        var selected: [String: Any] = ["requested_product": requested, "selected_cloud_id": id]
        for key in ["id", "product_id", "license_type", "feature_type", "active_flag"] { selected[key] = row[key] }
        let meta = row["game_meta"] as? [String: Any] ?? [:]
        for key in ["name", "package_type", "title_id", "concept_id", "conceptId"] { selected["game_" + key] = meta[key] }
        guard let data = try? JSONSerialization.data(withJSONObject: selected, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("last-license.json"), options: .atomic)
    }

    private static func recordMismatch(_ rows: [[String: Any]], requested: String?, conceptID: Int?, title: String?) {
        guard let title, let directory = Diagnostics.directory else { return }
        let wanted = title.lowercased().filter { $0.isLetter || $0.isNumber }
        let candidates = rows.compactMap { row -> [String: Any]? in
            let meta = row["game_meta"] as? [String: Any] ?? [:]
            let name = (meta["name"] as? String ?? "").lowercased()
            let normalized = name.filter { $0.isLetter || $0.isNumber }
            guard (!wanted.isEmpty && normalized.contains(wanted)) || row["product_id"] as? String == requested || row["id"] as? String == requested else { return nil }
            var safe: [String: Any] = ["game_meta": meta.filter { ["name", "package_type", "title_id", "concept_id", "conceptId"].contains($0.key) }]
            for key in ["id", "product_id", "license_type", "feature_type", "active_flag", "concept_id", "conceptId"] { safe[key] = row[key] }
            return safe
        }
        var result: [String: Any] = ["title": title, "candidates": candidates]
        result["requested_product"] = requested; result["concept_id"] = conceptID
        guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("license-mismatch.json"), options: .atomic)
    }

    static func rows(_ data: Data) throws -> [[String: Any]] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = object["entitlements"] as? [[String: Any]], rows.count <= 300 else { throw Failure.invalidResponse }
        return rows
    }
    static func select(_ rows: [[String: Any]], productID: String?, conceptID: Int? = nil, nativeOnly: Bool = false) -> String? {
        let matches = rows.filter {
            (!nativeOnly || isNativePS5($0)) && productID != nil && ($0["product_id"] as? String == productID || $0["id"] as? String == productID) && $0["active_flag"] as? Bool == true &&
            ($0["id"] as? String).map(validID) == true &&
            isWholeGame($0) && launchIdentifier($0) != nil
        }
        if let exact = preferredLicense(matches) {
            return launchIdentifier(exact)
        }
        guard let conceptID, conceptID > 0 else { return nil }
        let alternatives = rows.filter { row in
            guard !nativeOnly || isNativePS5(row), row["active_flag"] as? Bool == true,
                  (row["id"] as? String).map(validID) == true,
                  isWholeGame(row),
                  let product = row["product_id"] as? String, validID(product), launchIdentifier(row) != nil else { return false }
            return concept(of: row) == conceptID
        }
        return preferredLicense(alternatives).flatMap(launchIdentifier)
    }
    private static func isWholeGame(_ row: [String: Any]) -> Bool {
        let package = (row["game_meta"] as? [String: Any])?["package_type"] as? String ?? ""
        return CloudAllocation.integer(row["feature_type"]) == 3 || package.hasSuffix("GD") || package.hasSuffix("GS")
    }
    private static func isNativePS5(_ row: [String: Any]) -> Bool {
        (row["id"] as? String)?.contains("-PPSA") == true
    }
    private static func nativeSelection(_ rows: [[String: Any]], productID: String?, conceptID: Int?, products: Set<String>) -> String? {
        select(rows, productID: productID, conceptID: conceptID, nativeOnly: true)
            ?? selectEdition(rows, products: products, nativeOnly: true)
            ?? selectSameTitle(rows, productID: productID, nativeOnly: true)
    }
    static func selection(_ rows: [[String: Any]], productID: String?, conceptID: Int? = nil, products: Set<String> = []) -> String? {
        nativeSelection(rows, productID: productID, conceptID: conceptID, products: products)
            ?? select(rows, productID: productID, conceptID: conceptID)
            ?? selectEdition(rows, products: products)
            ?? selectSameTitle(rows, productID: productID)
    }

    private static func preferredLicense(_ rows: [[String: Any]]) -> [String: Any]? {
        rows.first { isNativePS5($0) && CloudAllocation.integer($0["license_type"]) == 4 }
            ?? rows.first { isNativePS5($0) && (($0["game_meta"] as? [String: Any])?["package_type"] as? String ?? "").hasSuffix("GS") }
            ?? rows.first { isNativePS5($0) }
            ?? rows.first { CloudAllocation.integer($0["license_type"]) == 4 }
            ?? rows.first
    }

    static func selectSameTitle(_ rows: [[String: Any]], productID: String?, nativeOnly: Bool = false) -> String? {
        guard let title = productID.flatMap(titleID), title.hasPrefix("PPSA") else { return nil }
        let licenses = rows.filter { row in
            guard !nativeOnly || isNativePS5(row), row["active_flag"] as? Bool == true, (row["id"] as? String).map(validID) == true,
                  let product = row["product_id"] as? String, validID(product), launchIdentifier(row).flatMap(titleID) == title else { return false }
            return isWholeGame(row)
        }
        return preferredLicense(licenses).flatMap(launchIdentifier)
    }
    static func launchIdentifier(_ row: [String: Any]) -> String? {
        guard let id = row["id"] as? String, validID(id) else { return nil }
        let productID = row["product_id"] as? String ?? ""
        if productID.contains("-CUSA"), !id.contains("-PPSA") { return nil }
        if validID(productID), productID.contains("-PPSA"), id.contains("-CUSA") { return productID }
        return id.contains("-CUSA") ? nil : id
    }

    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_-".contains($0)) }
    }
}
