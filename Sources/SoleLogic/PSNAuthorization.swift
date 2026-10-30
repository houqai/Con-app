import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SoleCloud
import SoleCore

public protocol CredentialStore: Sendable {
    func read(_ account: String) async throws -> Data?
    func write(_ data: Data, account: String) async throws
    func remove(_ account: String) async throws
}
public struct CredentialStoreFailure: Error {
    public let message: String
    public init(_ message: String) { self.message = message }
}

public struct SonyLogin: Sendable {
    public let code: String
    public let sso: SonySSO?
    public init(code: String, sso: SonySSO?) { self.code = code; self.sso = sso }
}
@MainActor public protocol SonyLoginPage: AnyObject {
    func signIn(url: URL, state: String) async throws -> SonyLogin
    func cancel()
}

@MainActor public final class PSNAuthorization {
    public nonisolated static let refreshAccount = "refresh", ssoAccount = "cloud-sso"
    private let store: CredentialStore
    private let website: SonyLoginPage
    private var websiteOpen = false
    private var revision = 0
    private var cachedSSO: SonySSO?
    private var cachedTokens: Tokens?
    private var tokenExpiry = Date.distantPast
    private var renewal: Task<Tokens?, Error>?
    private var renewalID: UUID?
    private let httpSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 25
        return .lasting(config)
    }()
    private static let base = "https://ca.account.sony.com/api/authz/v3/oauth"
    private static let clientID = SonyClients.account
    private static let redirect = PSNCallback.redirect
    private static let authorization = "Basic " + Data("\(SonyClients.account):\(SonyClients.accountSecret)".utf8).base64EncodedString()

    public init(store: CredentialStore, website: SonyLoginPage) { self.store = store; self.website = website }

    struct Tokens: Codable {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Double
        let idToken: String?
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in"
            case idToken = "id_token"
        }
    }
    public enum AuthError: LocalizedError {
        case cancelled, unavailable, timedOut, invalidCallback, identityUnavailable
        case callback(PSNCallback.Failure), service(Int, String, String?), storage(String), pageRefused(String)
        public var errorDescription: String? {
            switch self {
            case .cancelled: return loc("Sign-in cancelled.")
            case .unavailable: return loc("Could not open the sign-in page. Try again.")
            case .timedOut: return loc("The sign-in page did not respond. Close the browser window and try again.")
            case .invalidCallback: return loc("PlayStation did not confirm the sign-in. Try signing in again.")
            case .callback(let failure):
                switch failure {
                case .missingState: return loc("Sony did not return a confirmation of the sign-in request. The sign-in was not saved.")
                case .stateMismatch: return loc("Sony's answer belongs to a different sign-in request. Try again.")
                case .missingCode: return loc("Sony did not return an authorization code. Try again.")
                case .provider(let code): return code == "login_required" ? loc("Sony asks you to sign in again. Repeat the sign-in on the PlayStation page.") : loc("Sony rejected the sign-in request (%@).", code)
                case .invalid: return loc("Sony returned an unsuitable confirmation address. The sign-in was not saved.")
                }
            case .identityUnavailable: return loc("Sony did not return the account ID. The sign-in was not saved.")
            case .service(let status, let step, let reason): return loc("%@: Sony returned error %@", step, status) + (reason.map { " (\($0))" } ?? "") + "."
            case .storage(let message): return message
            case .pageRefused(let message): return message
            }
        }
    }
    static func signInURL(state: String) -> URL {
        var url = URLComponents(string: base + "/authorize")!
        url.queryItems = [
            .init(name: "access_type", value: "offline"), .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect), .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "psn:mobile.v2.core psn:clientapp"), .init(name: "state", value: state),
            .init(name: "prompt", value: "login"), .init(name: "ui", value: "pr"),
            .init(name: "service_entity", value: "urn:service-entity:psn"), .init(name: "service_logo", value: "ps")
        ]
        return url.url!
    }
    public func signIn() async throws -> PSNProfile {
        guard !websiteOpen else { throw AuthError.unavailable }
        websiteOpen = true
        defer { websiteOpen = false }
        revision += 1
        let currentRevision = revision
        let state = UUID().uuidString + UUID().uuidString
        let login = try await website.signIn(url: Self.signInURL(state: state), state: state)
        try ensureCurrent(currentRevision)
        let tokens = try await exchange(["code": login.code, "grant_type": "authorization_code", "redirect_uri": Self.redirect, "token_format": "jwt"])
        try ensureCurrent(currentRevision)
        try await save(tokens.refreshToken)
        if let sso = login.sso {
            try await saveSSO(sso)
        } else {
            cachedSSO = nil
            try await stored { try await store.remove(Self.ssoAccount) }
        }
        try ensureCurrent(currentRevision)
        cache(tokens)
        let account = try await profile(tokens)
        try ensureCurrent(currentRevision)
        return account
    }
    public func restore() async throws -> PSNProfile? {
        let currentRevision = revision
        guard let tokens = try await freshTokens() else { return nil }
        guard revision == currentRevision, !Task.isCancelled else { throw AuthError.cancelled }
        let account = try await profile(tokens)
        try ensureCurrent(currentRevision)
        return account
    }
    private func ensureCurrent(_ expected: Int) throws {
        try Task.checkCancellation()
        guard revision == expected else { throw AuthError.cancelled }
    }
    private func exchange(_ fields: [String: String]) async throws -> Tokens {
        var request = URLRequest(url: URL(string: Self.base + "/token")!)
        request.httpMethod = "POST"; request.timeoutInterval = 25
        request.setValue(Self.authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = PSNCallback.formBody(fields)
        let (data, response) = try await httpSession.plainData(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Self.serviceError(status, step: loc("Code and token exchange"), data: data) }
        let result = try JSONDecoder().decode(Tokens.self, from: data)
        guard !result.accessToken.isEmpty, !result.refreshToken.isEmpty else { throw AuthError.invalidCallback }
        return result
    }
    private func accountID(_ tokens: Tokens) async throws -> String {
        if let id = PSNIdentity.accountID(fromJWT: tokens.accessToken) { return id }
        if let token = tokens.idToken, let id = PSNIdentity.accountID(fromJWT: token) { return id }
        let url = URL(string: Self.base + "/token")!.appendingPathComponent(tokens.accessToken)
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 25
        request.setValue(Self.authorization, forHTTPHeaderField: "Authorization")
        let (data, response) = try await httpSession.plainData(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Self.serviceError(status, step: loc("Getting the account ID"), data: data) }
        guard let id = PSNIdentity.accountID(fromTokenInfo: data) else { throw AuthError.identityUnavailable }
        return id
    }
    private func profile(_ tokens: Tokens) async throws -> PSNProfile {
        let id = try await accountID(tokens)
        var request = URLRequest(url: URL(string: "https://m.np.playstation.com/api/userProfile/v1/internal/users/\(id)/profiles")!)
        request.timeoutInterval = 25
        request.setValue("Bearer " + tokens.accessToken, forHTTPHeaderField: "Authorization")
        let (data, response) = try await httpSession.plainData(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Self.serviceError(status, step: loc("Loading the profile"), data: data) }
        guard let profile = PSNProfile.decode(data) else { throw AuthError.invalidCallback }
        return profile
    }

    private func stored<T: Sendable>(_ work: () async throws -> T) async throws -> T {
        do { return try await work() } catch let failure as CredentialStoreFailure { throw AuthError.storage(failure.message) }
    }
    private func save(_ token: String) async throws {
        try await stored { try await store.write(Data(token.utf8), account: Self.refreshAccount) }
    }
    private func saveSSO(_ credential: SonySSO) async throws {
        let encoded = try JSONEncoder().encode(credential)
        try await stored { try await store.write(encoded, account: Self.ssoAccount) }
        cachedSSO = credential
    }
    public func signOut() async throws {
        cancel()
        cachedSSO = nil
        cachedTokens = nil; tokenExpiry = .distantPast
        try await stored {
            try await store.remove(Self.refreshAccount)
            try await store.remove(Self.ssoAccount)
        }
    }

    public func cancel() {
        revision += 1
        renewal?.cancel(); renewal = nil; renewalID = nil
        website.cancel()
    }
    private func cache(_ tokens: Tokens) {
        cachedTokens = tokens
        tokenExpiry = Date().addingTimeInterval(max(0, tokens.expiresIn - 60))
    }
    public func cloudSSO() async throws -> String {
        if let cachedSSO, cachedSSO.isValid { return cachedSSO.value }
        let currentRevision = revision
        let stored = try await stored { try await store.read(Self.ssoAccount) }
        guard currentRevision == revision, !Task.isCancelled else { throw CloudProtocol.Failure.cancelled }
        guard let stored, let credential = try? JSONDecoder().decode(SonySSO.self, from: stored), credential.isValid else {
            throw CloudProtocol.Failure.websiteSessionRequired
        }
        cachedSSO = credential
        return credential.value
    }
    public func psnAccountIDBytes() async throws -> [UInt8] {
        let currentRevision = revision
        guard let tokens = try await freshTokens() else { throw AuthError.cancelled }
        guard revision == currentRevision, !Task.isCancelled else { throw AuthError.cancelled }
        let id = try await accountID(tokens)
        guard let bytes = PSNIdentity.accountIDBytes(id) else { throw AuthError.identityUnavailable }
        return bytes
    }
    private func freshTokens() async throws -> Tokens? {
        if let cachedTokens, tokenExpiry > Date() { return cachedTokens }
        if let renewal { return try await renewal.value }
        let id = UUID(); renewalID = id
        let currentRevision = revision
        let task = Task { @MainActor [self] () throws -> Tokens? in
            guard let refresh = try await stored({ try await store.read(Self.refreshAccount) }).map({ String(decoding: $0, as: UTF8.self) }) else { return nil }
            try ensureCurrent(currentRevision)
            let tokens = try await exchange(["refresh_token": refresh, "grant_type": "refresh_token", "token_format": "jwt", "scope": "psn:mobile.v2.core psn:clientapp"])
            try ensureCurrent(currentRevision)
            try await save(tokens.refreshToken)
            try ensureCurrent(currentRevision)
            cache(tokens)
            return tokens
        }
        renewal = task
        defer { if renewalID == id { renewal = nil; renewalID = nil } }
        return try await task.value
    }
    private func accessToken() async throws -> String {
        guard let tokens = try await freshTokens() else { throw AuthError.cancelled }
        return tokens.accessToken
    }
    public func playedGames() async throws -> [PlayedTitle] {
        let token = try await accessToken()
        var titles: [PlayedTitle] = []
        var seen = Set<String>()
        var offset = 0
        for _ in 0..<20 {
            try Task.checkCancellation()
            var url = URLComponents(string: "https://m.np.playstation.com/api/gamelist/v2/users/me/titles")!
            url.queryItems = [.init(name: "limit", value: "100"), .init(name: "offset", value: String(offset))]
            var request = URLRequest(url: url.url!)
            request.timeoutInterval = 25
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            let (data, response) = try await httpSession.plainData(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { throw Self.serviceError(status, step: loc("Loading games"), data: data) }
            let page = try JSONDecoder().decode(PlayedGamesPage.self, from: data)
            titles.append(contentsOf: page.titles.filter { !$0.id.isEmpty && seen.insert($0.id).inserted })
            guard !page.titles.isEmpty, let next = page.nextOffset, next > offset else { break }
            offset = next
        }
        return titles
    }

    public struct TrophyResponse: Sendable {
        public let summaryStatus: Int
        public let titlesStatus: Int?
        public let trophies: AccountTrophies?
        public init(summaryStatus: Int, titlesStatus: Int?, trophies: AccountTrophies?) {
            self.summaryStatus = summaryStatus; self.titlesStatus = titlesStatus; self.trophies = trophies
        }
    }
    public func trophies(titles limit: Int) async throws -> TrophyResponse {
        let token = try await accessToken()
        func get(_ path: String) async throws -> (data: Data, status: Int) {
            var request = URLRequest(url: URL(string: "https://m.np.playstation.com/api/trophy/v1/users/me/" + path)!)
            request.timeoutInterval = 25
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            let (data, response) = try await httpSession.plainData(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let summary = try await get("trophySummary")
        guard (200..<300).contains(summary.status), let read = TrophySummary.decode(summary.data) else {
            return TrophyResponse(summaryStatus: summary.status, titlesStatus: nil, trophies: nil)
        }
        try Task.checkCancellation()
        let titles = try? await get("trophyTitles?limit=\(limit)&offset=0")
        let listed = titles.flatMap { (200..<300).contains($0.status) ? TrophyTitle.list($0.data) : nil } ?? []
        return TrophyResponse(summaryStatus: summary.status, titlesStatus: titles?.status ?? 0, trophies: AccountTrophies(summary: read, titles: listed))
    }

    private func trophyData(_ path: String, language: String? = nil) async throws -> (data: Data, status: Int) {
        let token = try await accessToken()
        guard let url = URL(string: "https://m.np.playstation.com/api/trophy/v1/" + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let language { request.setValue(language, forHTTPHeaderField: "Accept-Language") }
        let (data, response) = try await httpSession.plainData(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
    public func trophyTitles(limit: Int) async throws -> (status: Int, titles: [TrophyTitle]) {
        let answer = try await trophyData("users/me/trophyTitles?limit=\(limit)&offset=0")
        return (answer.status, (200..<300).contains(answer.status) ? TrophyTitle.list(answer.data) : [])
    }
    public func earnedTrophies(of title: TrophyTitle) async throws -> (status: Int, trophies: [EarnedTrophy]) {
        guard let id = Self.trophyListID(title.id) else { return (0, []) }
        let answer = try await trophyData("users/me/npCommunicationIds/\(id)/trophyGroups/all/trophies?npServiceName=\(title.serviceName)")
        return (answer.status, (200..<300).contains(answer.status) ? EarnedTrophy.list(answer.data) : [])
    }
    public func definedTrophies(of title: TrophyTitle, language: String) async throws -> (status: Int, trophies: [TrophyDefinition]) {
        guard let id = Self.trophyListID(title.id) else { return (0, []) }
        let answer = try await trophyData("npCommunicationIds/\(id)/trophyGroups/all/trophies?npServiceName=\(title.serviceName)", language: language)
        return (answer.status, (200..<300).contains(answer.status) ? TrophyDefinition.list(answer.data) : [])
    }
    nonisolated static func trophyListID(_ id: String) -> String? {
        !id.isEmpty && id.count <= 32 && id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) ? id : nil
    }

    static func serviceError(_ status: Int, step: String, data: Data) -> AuthError {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        var reason: String?
        if let value = object?["error"] as? String {
            let known = ["invalid_grant", "invalid_client", "invalid_request", "invalid_scope", "access_denied", "expired_token"]
            if known.contains(value) { reason = value }
        }
        if let error = object?["error"] as? [String: Any], let code = error["code"] as? Int { reason = String(code) }
        return .service(status, step, reason)
    }
}
