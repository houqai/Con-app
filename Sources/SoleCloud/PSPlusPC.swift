import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SoleCore

public enum CloudBackend: String, Sendable { case ps5, psPlusPC, ps3 }

public actor PSPlusPCService {
    public static let redirect = CloudEntitlementService.redirect
    public static let userAgent = "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) playstation-now/0.0.0 Chrome/83.0.4103.104 Electron/9.0.4 Safari/537.36 gkApollo"
    public enum Failure: Error { case unsupportedRegion, unavailable, invalidResponse, service(Int), notFree, activationFailed }
    public struct Title: Sendable {
        public let productID: String
        public let name: String
        public let artworkURL: URL?
        public let backend: CloudBackend
    }
    private let http: URLSession
    private var cookie: String?
    private var trace: [[String: Any]] = []
    private var cachedTitles: [Title] = []
    private var cachedAt = Date.distantPast
    private var credentialHash: Data?
    private var streamingSKU: String?
    private var baseURL: URL?
    private var screenshotCache: [String: [URL]] = [:]
    private static let pcClientID = SonyClients.catalog
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil; configuration.timeoutIntervalForRequest = 25
        http = .lasting(configuration, delegate: NoRedirects())
    }
    public static func authorizationURL(clientID: String, scope: String, state: String, deviceID: String) throws -> URL {
        guard UUID(uuidString: clientID) != nil, !state.isEmpty, deviceID.count == 48,
              deviceID.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw CloudProtocol.Failure.invalidResponse }
        var url = URLComponents(string: "https://ca.account.sony.com/api/v1/oauth/authorize")!
        url.queryItems = ["client_id": clientID, "redirect_uri": redirect, "response_type": "code", "scope": scope,
            "state": state, "duid": deviceID, "prompt": "none", "smcid": "pc:psnow", "applicationId": "psnow",
            "mid": "PSNOW", "service_entity": "urn:service-entity:psn", "layout_type": "popup", "service_logo": "ps", "tp_psn": "true", "noEVBlock": "true"].map { .init(name: $0.key, value: $0.value) }
        return url.url!
    }
    public static func code(from callback: URL, state: String) throws -> String {
        guard let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host == "psnow.playstation.com", parts.port == nil,
              parts.user == nil, parts.password == nil, parts.path == URL(string: redirect)!.path,
              parts.fragment == nil, !state.isEmpty else { throw CloudProtocol.Failure.invalidCallback }
        let fields = parts.queryItems ?? []
        guard fields.filter({ $0.name == "state" }).count == 1, fields.first(where: { $0.name == "state" })?.value == state else { throw CloudProtocol.Failure.invalidCallback }
        if let error = fields.first(where: { $0.name == "error" })?.value { throw CloudProtocol.Failure.provider(CloudProtocol.safeProviderError(error) ?? "unknown") }
        let codes = fields.filter { $0.name == "code" }
        guard codes.count == 1, let code = codes.first?.value, !code.isEmpty, code.count < 16384,
              !code.contains("\r"), !code.contains("\n"), !code.contains("\0") else { throw CloudProtocol.Failure.invalidCallback }
        return code
    }
    public func grant(sso: String, deviceID: String, clientID: String, scope: String, omitDeviceID: Bool = false) async throws -> String {
        guard SonySSO.validValue(sso) else { throw CloudProtocol.Failure.websiteSessionRequired }
        let state = UUID().uuidString
        var parts = URLComponents(url: try Self.authorizationURL(clientID: clientID, scope: scope, state: state, deviceID: deviceID), resolvingAgainstBaseURL: false)!
        if omitDeviceID { parts.queryItems = parts.queryItems?.filter { $0.name != "duid" } }
        var request = URLRequest(url: parts.url!)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("npsso=" + sso, forHTTPHeaderField: "Cookie")
        let (_, response) = try await http.plainData(for: request)
        if let response = response as? HTTPURLResponse { record(["step": "oauth", "status": response.statusCode]) }
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, (300..<400).contains(response.statusCode),
              let location = response.value(forHTTPHeaderField: "Location"), let callback = URL(string: location) else { throw CloudProtocol.Failure.unauthorized }
        return try Self.code(from: callback, state: state)
    }
    public func catalog(sso: String, deviceID: String, force: Bool = false) async throws -> [Title] {
        let hash = SHA256Digest.hash(Data(sso.utf8))
        if !force, credentialHash == hash, cookie != nil, baseURL != nil, Date().timeIntervalSince(cachedAt) < 300, !cachedTitles.isEmpty { return cachedTitles }
        trace = []
        let code = try await grant(sso: sso, deviceID: deviceID, clientID: Self.pcClientID, scope: "kamaji:commerce_native kamaji:commerce_container kamaji:lists kamaji:s2s.subscriptionsPremium.get")
        var form = URLComponents()
        form.queryItems = [.init(name: "code", value: code), .init(name: "client_id", value: Self.pcClientID), .init(name: "duid", value: deviceID)]
        var session: String?
        let (answer, response) = try await request(URL(string: "https://psnow.playstation.com/kamaji/api/pcnow/00_09_000/user/session")!, body: form.percentEncodedQuery, cookie: &session)
        guard (answer["header"] as? [String: Any])?["status_code"] as? String == "0x0000" else { throw CloudProtocol.Failure.unauthorized }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: response.allHeaderFields.reduce(into: [String: String]()) { if let key = $1.key as? String { $0[key] = String(describing: $1.value) } }, for: response.url!)
        guard let sessionCookie = cookies.first(where: { $0.name == "JSESSIONID" }), !sessionCookie.value.contains("\r"), !sessionCookie.value.contains("\n") else { throw Failure.invalidResponse }
        session = "JSESSIONID=" + sessionCookie.value
        let (stores, _) = try await request(URL(string: "https://psnow.playstation.com/kamaji/api/pcnow/00_09_000/user/stores")!, cookie: &session)
        guard let base = (stores["data"] as? [String: Any])?["base_url"] as? String, let store = Self.storeURL(base) else { throw Failure.unsupportedRegion }
        let (root, _) = try await request(Self.paged(store, start: 0, size: 100), cookie: &session)
        let categories = (root["links"] as? [[String: Any]] ?? []).filter { ["A - B", "C - D", "E - G", "H - L", "M - O", "P - R", "S", "T", "U - Z"].contains($0["name"] as? String ?? "") }
        guard !categories.isEmpty else { throw Failure.invalidResponse }
        var result: [Title] = []; var seen = Set<String>()
        for category in categories {
            guard let text = category["url"] as? String, let url = Self.storeURL(text) else { throw Failure.invalidResponse }
            for page in 0..<20 {
                let (object, _) = try await request(Self.paged(url, start: page * 500, size: 500), cookie: &session)
                let rows = object["links"] as? [[String: Any]] ?? []
                for row in rows {
                    guard let title = Self.title(row), seen.insert(title.productID).inserted else { continue }
                    result.append(title)
                }
                if rows.count < 500 { break }
                if page == 19 { throw Failure.invalidResponse }
            }
        }
        cookie = session; baseURL = store; cachedTitles = result; cachedAt = Date(); credentialHash = hash
        record(["step": "catalog", "count": result.count])
        return result
    }
    static func supportedProductID(_ id: String) -> Bool {
        guard CloudEntitlementService.validID(id), let title = titlePrefix(id) else { return false }
        return ["CUSA", "NPUB", "NPEB", "NPJB", "NPHB", "BLUS", "BLES", "BLJS", "BCUS", "BCES", "BCJS"].contains { title.hasPrefix($0) }
    }
    private static func titlePrefix(_ id: String) -> String? {
        id.split(separator: "-").dropFirst().first?.split(separator: "_").first.map(String.init)
    }
    private static func skus(_ product: [String: Any]) -> [[String: Any]] {
        [product["default_sku"] as? [String: Any]].compactMap { $0 } + (product["skus"] as? [[String: Any]] ?? [])
    }
    public func reset() { cookie = nil; baseURL = nil; streamingSKU = nil; cachedTitles = []; credentialHash = nil; cachedAt = .distantPast }
    static func title(_ row: [String: Any]) -> Title? {
        guard let id = row["id"] as? String, CloudEntitlementService.validID(id), Self.supportedProductID(id),
              let name = row["name"] as? String, !name.isEmpty else { return nil }
        let metadata = row["metadata"] as? [String: Any] ?? [:]
        let platforms = row["playable_platform"] as? [String] ?? (metadata["playable_platform"] as? [String: Any])?["values"] as? [String] ?? []
        let isPS4 = id.contains("-CUSA")
        guard platforms.contains(where: { $0.uppercased().contains(isPS4 ? "PS4" : "PS3") }) else { return nil }
        let images = row["images"] as? [[String: Any]] ?? []
        let image = images.first(where: { ($0["type"] as? Int) == 10 }) ?? images.first
        let artwork = (image?["url"] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" && $0.user == nil && $0.password == nil ? $0 : nil }
        return Title(productID: id, name: name, artworkURL: artwork, backend: isPS4 ? .psPlusPC : .ps3)
    }
    public func screenshots(productID: String) async throws -> [URL] {
        if let cached = screenshotCache[productID] { return cached }
        guard CloudEntitlementService.validID(productID), Self.supportedProductID(productID), let baseURL else { return [] }
        let url = baseURL.deletingLastPathComponent().appendingPathComponent(productID)
        let (product, _) = try await request(url)
        let result = Self.screenshotURLs(product)
        screenshotCache[productID] = result
        return result
    }
    static func screenshotURLs(_ product: [String: Any]) -> [URL] {
        var seen = Set<String>()
        let materials = (product["promomedia"] as? [[String: Any]] ?? []).flatMap { $0["materials"] as? [[String: Any]] ?? [] }
        let modern = ((product["mediaList"] as? [String: Any])?["screenshots"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "SCREENSHOT" || CloudAllocation.integer($0["typeId"]) == 4 }.map { row -> [String: Any] in
            var row = row; row["type"] = 26; return row
        }
        return Array((modern + materials.flatMap { $0["urls"] as? [[String: Any]] ?? [] }).compactMap { row -> URL? in
            guard CloudAllocation.integer(row["type"]) == 26, let text = row["url"] as? String,
                  let url = URL(string: text), url.scheme == "https", url.user == nil, url.password == nil,
                  let host = url.host, host.hasSuffix(".playstation.net") || host.hasSuffix(".playstation.com"),
                  seen.insert(text).inserted else { return nil }
            return url
        }.prefix(6))
    }
    public func resolve(productID: String) async throws -> String {
        guard CloudEntitlementService.validID(productID), Self.supportedProductID(productID), let baseURL else { throw Failure.unavailable }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        var paths = baseURL.path.components(separatedBy: "/"); paths[paths.count - 1] = productID
        components.path = paths.joined(separator: "/")
        components.queryItems = [.init(name: "useOffers", value: "true"), .init(name: "gkb", value: "1"), .init(name: "gkb2", value: "1")]
        let (product, _) = try await request(components.url!)
        guard let entitlement = Self.entitlement(product, productID: productID) else { throw Failure.unavailable }
        streamingSKU = Self.skus(product).first { ($0["entitlements"] as? [[String: Any]] ?? []).contains { $0["id"] as? String == entitlement } }?["id"] as? String
        return entitlement
    }
    public func ensureStreamingLicense(entitlementID: String, sso: String, deviceID: String) async throws {
        guard CloudEntitlementService.validID(entitlementID), Self.supportedProductID(entitlementID), SonySSO.validValue(sso) else { throw Failure.invalidResponse }
        let state = UUID().uuidString
        var parts = URLComponents(url: try Self.authorizationURL(clientID: CloudEntitlementService.clientID, scope: "kamaji:get_internal_entitlements user:account.attributes.validate kamaji:get_privacy_settings user:account.settings.privacy.get kamaji:s2s.subscriptionsPremium.get", state: state, deviceID: deviceID), resolvingAgainstBaseURL: false)!
        parts.queryItems = parts.queryItems?.filter { $0.name != "response_type" }
        parts.queryItems?.append(.init(name: "response_type", value: "token"))
        var oauth = URLRequest(url: parts.url!)
        oauth.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent"); oauth.setValue("npsso=" + sso, forHTTPHeaderField: "Cookie")
        let (_, response) = try await http.plainData(for: oauth)
        guard let response = response as? HTTPURLResponse, (300..<400).contains(response.statusCode),
              let location = response.value(forHTTPHeaderField: "Location"), let callback = URL(string: location) else { throw CloudProtocol.Failure.unauthorized }
        let token = try CloudEntitlementService.token(from: callback, expectedState: state)
        var check = URLRequest(url: URL(string: "https://commerce.api.np.km.playstation.net/commerce/api/v1/users/me/internal_entitlements/\(entitlementID)?fields=game_meta")!)
        check.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, licenseResponse) = try await http.plainData(for: check)
        try Task.checkCancellation()
        guard let licenseResponse = licenseResponse as? HTTPURLResponse else { throw Failure.invalidResponse }
        record(["step": "streaming-license", "status": licenseResponse.statusCode])
        if licenseResponse.statusCode == 200 {
            let row = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if row?["active_flag"] as? Bool == false { throw Failure.unavailable }
            return
        }
        guard licenseResponse.statusCode == 404, let sku = streamingSKU, CloudEntitlementService.validID(sku) else { throw Failure.service(licenseResponse.statusCode) }
        let (preview, _) = try await request(URL(string: "https://psnow.playstation.com/kamaji/api/pcnow/00_09_000/user/checkout/buynow/preview")!, body: "sku=" + sku, bearer: token)
        guard let approvedSKU = Self.freeStreamingSKU(preview, expectedSKU: sku) else { throw Failure.notFree }
        record(["step": "free-streaming-license", "price": 0])
        try Task.checkCancellation()
        let (acquired, _) = try await request(URL(string: "https://psnow.playstation.com/kamaji/api/pcnow/00_09_000/user/checkout/buynow")!, body: "sku=" + approvedSKU + "&skipEmail=true", bearer: token)
        guard (acquired["header"] as? [String: Any])?["status_code"] as? String == "0x0000" else { throw Failure.activationFailed }
    }
    static func freeStreamingSKU(_ preview: [String: Any], expectedSKU: String) -> String? {
        guard (preview["header"] as? [String: Any])?["status_code"] as? String == "0x0000",
              let cart = (preview["data"] as? [String: Any])?["cart"] as? [String: Any],
              CloudAllocation.integer(cart["total_price_value"]) == 0,
              let items = cart["items"] as? [[String: Any]], items.count == 1,
              let sku = items.first?["sku_id"] as? String, sku == expectedSKU, CloudEntitlementService.validID(sku) else { return nil }
        return sku
    }
    static func entitlement(_ product: [String: Any], productID: String) -> String? {
        let rows = skus(product).flatMap { $0["entitlements"] as? [[String: Any]] ?? [] }
        let title = titlePrefix(productID)
        let valid = rows.filter { row in
            guard let id = row["id"] as? String, CloudEntitlementService.validID(id), Self.supportedProductID(id),
                  let title, titlePrefix(id) == title else { return false }
            let meta = row["game_meta"] as? [String: Any] ?? [:]
            let package = meta["package_type"] as? String ?? ""
            return CloudAllocation.integer(row["license_type"]) == 4 || (package == "PS4GS" || package == "PS3GS") || CloudAllocation.integer(row["feature_type"]) == 3
        }
        return (valid.first { CloudAllocation.integer($0["license_type"]) == 4 } ?? valid.first { ($0["game_meta"] as? [String: Any])?["package_type"] as? String == "PS4GS" } ?? valid.first)?["id"] as? String
    }
    static func storeURL(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme == "https", url.host == "psnow.playstation.com", url.port == nil,
              url.user == nil, url.password == nil, url.path.hasPrefix("/store/api/pcnow/00_09_000/container/") else { return nil }
        return url
    }
    private static func paged(_ url: URL, start: Int, size: Int) -> URL {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        parts.queryItems = (parts.queryItems ?? []).filter { !["start", "size"].contains($0.name) } + [.init(name: "start", value: String(start)), .init(name: "size", value: String(size))]
        return parts.url!
    }
    private func record(_ event: [String: Any]) {
        trace.append(event)
        guard let directory = Diagnostics.directory,
              let data = try? JSONSerialization.data(withJSONObject: trace, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("pc-catalog.json"), options: .atomic)
    }
    private func request(_ url: URL, body: String? = nil, bearer: String? = nil) async throws -> ([String: Any], HTTPURLResponse) {
        let sent = cookie
        var session = sent
        defer { if session != sent, cookie == sent { cookie = session } }
        return try await request(url, body: body, bearer: bearer, cookie: &session)
    }
    private func request(_ url: URL, body: String? = nil, bearer: String? = nil, cookie session: inout String?) async throws -> ([String: Any], HTTPURLResponse) {
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://psnow.playstation.com", forHTTPHeaderField: "Origin")
        request.setValue(String(Self.redirect.dropLast("grc-response.html".count)), forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer {
            request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
            request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        }
        if let session { request.setValue(session, forHTTPHeaderField: "Cookie") }
        if let body {
            request.httpMethod = "POST"
            request.httpBody = Data(body.utf8)
            request.setValue(bearer == nil ? "text/plain;charset=UTF-8" : "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue(Self.redirect, forHTTPHeaderField: "X-Alt-Referer")
        }
        let (data, response) = try await http.plainData(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        record(["step": url.path, "status": response.statusCode])
        if let fields = response.allHeaderFields as? [String: String], let updated = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url).first(where: { $0.name == "JSESSIONID" }) {
            session = "JSESSIONID=" + updated.value
        }
        guard response.statusCode == 200 else { throw Failure.service(response.statusCode) }
        guard data.count < 15_000_000, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.invalidResponse }
        return (object, response)
    }
}
