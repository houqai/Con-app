import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SoleCore

public enum CloudProtocol {
    public static let redirect = "gaikai://local"
    public enum Failure: Error {
        case invalidResponse
        case invalidCallback
        case service(Int, String)
        case unauthorized
        case cancelled
        case websiteSessionRequired
        case provider(String)
        case grant(String, String)
        case serviceEvent(Int, String, String)
        case sessionBusy
        case serviceCode(Int, String, String, String)
    }
    public struct Session: Decodable, Sendable {
        public let sessionId: String
        public let gkClientId: String
        public let streamServerClientId: String
        public func validate() throws {
            guard !sessionId.isEmpty, sessionId.count <= 128,
                  sessionId.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
                  UUID(uuidString: gkClientId) != nil, UUID(uuidString: streamServerClientId) != nil else { throw Failure.invalidResponse }
        }
    }
    public static func authorizationURL(clientID: String, streamServer: Bool, state: String, deviceID: String) throws -> URL {
        guard UUID(uuidString: clientID) != nil, !state.isEmpty,
              deviceID.count == 48, deviceID.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { throw Failure.invalidResponse }
        var url = URLComponents(string: "https://ca.account.sony.com/api/authz/v3/oauth/authorize")!
        url.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"), .init(name: "state", value: state), .init(name: "duid", value: deviceID),
            .init(name: "scope", value: streamServer ? "id_token:duid id_token:online_id openid oauth:create_authn_ticket_for_cloud_console_signin" : "id_token:psn.basic_claims kamaji:s2s.subscriptionsPremium.get id_token:duid id_token:online_id openid psn:s2s"),
            .init(name: "prompt", value: "none"), .init(name: "smcid", value: "qlite"), .init(name: "applicationId", value: "qlite"), .init(name: "mid", value: "qlite"), .init(name: "service_entity", value: "urn:service-entity:psn"), .init(name: "service_logo", value: "ps")
        ]
        guard let result = url.url else { throw Failure.invalidResponse }
        return result
    }
    public static func safeProviderError(_ value: String) -> String? {
        ["invalid_scope", "invalid_client", "invalid_request", "access_denied", "login_required", "invalid_grant"].contains(value) ? value : nil
    }
    public static func refusalReason(_ answer: [String: Any]) -> String? {
        let name = (answer["error"] as? String).flatMap { value -> String? in
            guard !value.isEmpty, value.count <= 40, value.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_") }) else { return nil }
            return value
        }
        let number = CloudAllocation.integer(answer["error_code"]).flatMap { (1...9_999_999).contains($0) ? $0 : nil }
        switch (name, number) {
        case (let name?, let number?): return "\(name) (\(number))"
        case (let name?, nil): return name
        case (nil, let number?): return String(number)
        case (nil, nil): return nil
        }
    }

    public static func code(from url: URL, expectedState: String) throws -> String {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "gaikai", parts.host?.lowercased() == "local",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/", !expectedState.isEmpty else { throw Failure.invalidCallback }
        let items = parts.queryItems ?? []
        let states = items.filter { $0.name == "state" }
        let codes = items.filter { $0.name == "code" }
        guard states.count == 1, states.first?.value == expectedState else { throw Failure.invalidCallback }
        if let error = items.first(where: { $0.name == "error" })?.value {
            throw Failure.provider(safeProviderError(error) ?? "unknown")
        }
        guard codes.count == 1,
              let code = codes.first?.value, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.invalidCallback }
        return code
    }
}

public actor CloudSessionService {
    private let http: URLSession
    private let recordsFailureDiagnostics: Bool
    private var active: CloudProtocol.Session?
    private var lockedKey: String?
    private var sessionKey: String?
    private var authorized = false
    private var specification: [String: Any] = [:]
    private var generation = UUID()
    private var selectedDatacenter: String?
    private var keyTrace: [[String: Any]] = []
    private(set) var lockTrace: [[String: Any]] = []
    private var lockCall: (forced: Bool, attempt: Int, firstStarted: ContinuousClock.Instant, started: ContinuousClock.Instant)?
    private var lockFirstStarted: ContinuousClock.Instant?
    private var traceStart = ContinuousClock.now
    private var backend: CloudBackend = .ps5
    public static let portalUserAgent = "PlayStation Portal/6.0.0-rel.444+6a9cea6f5"
    public init(session: URLSession? = nil, recordsFailureDiagnostics: Bool = false) {
        self.recordsFailureDiagnostics = recordsFailureDiagnostics
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 25
        http = session ?? .lasting(configuration, delegate: NoRedirects())
    }
    private struct Configuration: Decodable { let configKey: String }
    private struct Clients: Decodable { let gkClientId: String; let streamServerClientId: String; let ps3GkClientId: String? }
    private struct Started: Decodable { let sessionId: String }
    public func clients() async throws -> (cloud: String, stream: String) {
        let (data, _) = try await request(url: URL(string: "https://cc.prod.gaikai.com/v1/client_ids?virtType=cronos")!, stage: "PS5 Cloud clients")
        let result = try JSONDecoder().decode(Clients.self, from: data)
        guard UUID(uuidString: result.gkClientId) != nil, UUID(uuidString: result.streamServerClientId) != nil else { throw CloudProtocol.Failure.invalidResponse }
        return (result.gkClientId, result.streamServerClientId)
    }
    public static let widths = [360: 640, 540: 960, 720: 1280, 1080: 1920, 1440: 2560, 2160: 3840]
    public func begin(entitlementID: String? = nil, isPlusMember: Bool = true, height: Int = 1080, language: String = "en", backend: CloudBackend = .ps5) async throws -> CloudProtocol.Session {
        self.backend = backend
        let pc = backend != .ps5
        keyTrace = []; traceStart = .now; lockTrace = []; lockFirstStarted = nil
        let attempt = UUID()
        generation = attempt
        clearSession()
        let (clientData, _) = try await request(url: URL(string: "https://cc.prod.gaikai.com/v1/client_ids?virtType=\(backend == .ps3 ? "konan" : pc ? "kratos" : "cronos")")!, stage: "PS Cloud clients")
        let clients = try JSONDecoder().decode(Clients.self, from: clientData)
        guard UUID(uuidString: clients.gkClientId) != nil, UUID(uuidString: clients.streamServerClientId) != nil else { throw CloudProtocol.Failure.invalidResponse }
        try ensureCurrent(attempt)
        let (configuration, _) = try await request(url: URL(string: "https://config.cc.prod.gaikai.com/v1/config")!, method: "POST", body: ["product": pc ? "psnow" : "qlite", "platform": pc ? "PC" : "qlite", "sessionId": ""], stage: "Cloud configuration")
        let key = try JSONDecoder().decode(Configuration.self, from: configuration).configKey
        guard Self.validKey(key) else { throw CloudProtocol.Failure.invalidResponse }
        try ensureCurrent(attempt)
        sessionKey = key
        guard let width = Self.widths[height], GameLanguage.isKnown(language) else { throw CloudProtocol.Failure.invalidResponse }
        let offset = TimeZone.current.secondsFromGMT()
        let zone = String(format: "UTC%@%02d:%02d", offset >= 0 ? "+" : "-", abs(offset) / 3600, abs(offset) % 3600 / 60)
        specification = [
            "model": "portal", "platform": "qlite", "gaikaiPlayer": "16.4.0", "protocolVersion": 12,
            "capabilities": ["cloudDrivenSenkushaTest", "cronos"], "npEnv": "np",
            "audioUploadEnabled": false, "audioUploadNumChannels": 1, "audioUploadSamplingFrequency": 48000,
            "summerTime": TimeZone.current.isDaylightSavingTime() ? 1 : 0, "timeZone": zone,
            "httpUserAgent": Self.portalUserAgent,
            "partyCapability": false, "homesharing": false, "isFirstBoot": false, "yuvCoefficient": "",
            "isPlusMember": isPlusMember, "parentalLevel": 0,
            "accessibilityMarqueeSpeed": 0, "accessibilityLargeText": 0, "accessibilityBoldText": 0,
            "accessibilityContrast": 0, "accessibilityTtsEnable": 0, "accessibilityTtsSpeed": 0, "accessibilityTtsVolume": 0,
            "videoEncoderProfile": "hw5.0", "audioEncoderProfile": "default", "audioChannels": "2",
            "language": language, "acceptButton": "X", "connectedControllers": ["ds5"],
            "input": ["controllers": ["ds5"]], "encryptionSupported": true,
            "resolutionSetting": String(height), "clientWidth": width, "clientHeight": height,
            "adaptiveStreamMode": "resize", "useClientBwLadder": true,
            "redirectUri": CloudProtocol.redirect, "cloudEndpoint": "https://cc.prod.gaikai.com",
            "ps3AuthCode": "", "gkCloudAuthCode": "", "streamServerAuthCode": "",
            "videoStreamSettings": ["clientHeight": height, "supportedMaxResolution": height,
                "supportedVideoEncoderProfiles": ["hevc_hw4"], "supportedDynamicRange": "sdr",
                "preferredMaxResolution": height, "preferredDynamicRange": "sdr", "hqMode": 1],
            "audioStreamSettings": ["audioEncoderProfile": "default", "maxAudioChannels": "2", "preferredNumberAudioChannels": "2"]
        ]
        if pc {
            specification["model"] = "WINDOWS"; specification["platform"] = "PC"
            specification["gaikaiPlayer"] = "12.5.0"; specification["protocolVersion"] = 9
            specification["capabilities"] = ["cloudDrivenSenkushaTest", "kratos"]
            specification["redirectUri"] = PSPlusPCService.redirect
            specification["httpUserAgent"] = PSPlusPCService.userAgent
            specification["videoEncoderProfile"] = "hw4.1"
            specification["audioChannels"] = "2.1"
            specification["connectedControllers"] = ["xinput"]; specification["input"] = ["controllers": ["xinput"]]
            specification.removeValue(forKey: "videoStreamSettings"); specification.removeValue(forKey: "audioStreamSettings")
        }
        if let entitlementID {
            guard !entitlementID.isEmpty, entitlementID.count <= 128, entitlementID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_-".contains($0)) }) else { throw CloudProtocol.Failure.invalidResponse }
            specification["entitlementId"] = entitlementID
        }
        let (data, startResponse) = try await request(url: URL(string: "https://cc.prod.gaikai.com/v1/sessions/start?npEnv=np")!, method: "POST", body: ["requestGameSpecification": specification], stage: "Creating the cloud session")
        let started = try JSONDecoder().decode(Started.self, from: data)
        let session = CloudProtocol.Session(sessionId: started.sessionId, gkClientId: clients.gkClientId, streamServerClientId: pc ? (clients.ps3GkClientId ?? clients.streamServerClientId) : clients.streamServerClientId)
        try session.validate()
        try ensureCurrent(attempt)
        try rotateKey(startResponse)
        active = session
        return session
    }
    public func authorize(_ session: CloudProtocol.Session, cloudCode: String, streamCode: String) async throws {
        guard active?.sessionId == session.sessionId, !cloudCode.isEmpty, !streamCode.isEmpty else { throw CloudProtocol.Failure.cancelled }
        let attempt = generation
        authorized = false
        var authorizedSpecification = specification
        authorizedSpecification["gkCloudAuthCode"] = cloudCode; authorizedSpecification["streamServerAuthCode"] = streamCode
        if backend != .ps5 { authorizedSpecification["ps3AuthCode"] = streamCode }
        let (data, response) = try await request(url: Self.endpoint(session, "authorize"), method: "POST", body: ["requestGameSpecification": authorizedSpecification], stage: "Cloud authorization")
        try ensureCurrent(attempt)
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let key = response.value(forHTTPHeaderField: "X-Gaikai-Session") ?? body?["sessionKey"] as? String {
            guard Self.validKey(key) else { throw CloudProtocol.Failure.invalidResponse }
            sessionKey = key
        }
        guard sessionKey != nil else { throw CloudProtocol.Failure.invalidResponse }
        specification = authorizedSpecification; authorized = true
    }
    public func lock(forceLogout: Bool = false, tryNumber number: Int = 1) async throws {
        guard let session = active, authorized else { throw CloudProtocol.Failure.unauthorized }
        let attempt = generation
        let now = ContinuousClock.now
        if number <= 1 || lockFirstStarted == nil { lockFirstStarted = now }
        lockCall = (forceLogout, number, lockFirstStarted ?? now, now)
        defer { lockCall = nil }
        let (data, response) = try await request(url: Self.lockURL(session, forceLogout: forceLogout), method: "POST", body: ["requestGameSpecification": specification], stage: "Preparing the game session")
        try ensureCurrent(attempt)
        try rotateKey(response)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard object?["lockAcquired"] as? Bool == true else { throw CloudProtocol.Failure.sessionBusy }
        lockedKey = sessionKey
    }
    public static let forcedLockInterval: Duration = .seconds(5)
    public static let forcedLockLimit: Duration = .seconds(40)
    public static func acquireLock(_ service: CloudSessionService, forceLogout: Bool, interval: Duration = forcedLockInterval, limit: Duration = forcedLockLimit,
                                   isolation: isolated (any Actor)? = #isolation, waiting: (Int) throws -> Void = { _ in }) async throws {
        guard forceLogout else { try await service.lock(); return }
        let started = ContinuousClock.now
        var number = 1
        while true {
            do { try await service.lock(forceLogout: true, tryNumber: number); return }
            catch CloudProtocol.Failure.sessionBusy {
                let waited = started.duration(to: .now)
                guard waited + interval <= limit else { throw CloudProtocol.Failure.sessionBusy }
                try waiting(Int(waited.components.seconds))
                try await Task.sleep(for: interval)
                try Task.checkCancellation()
                number += 1
            }
        }
    }
    public func networkProbeCredential() throws -> String {
        guard authorized, let lockedKey else { throw CloudProtocol.Failure.unauthorized }
        return lockedKey
    }
    public func datacenterResponse() async throws -> Data {
        guard let session = active, authorized, sessionKey != nil else { throw CloudProtocol.Failure.unauthorized }
        let attempt = generation
        let (data, response) = try await request(url: Self.endpoint(session, "datacenters"), method: "POST", body: ["requestGameSpecification": specification], stage: "Datacenter list")
        try ensureCurrent(attempt)
        try rotateKey(response)
        recordDatacenterList(data)
        return data
    }
    private func recordDatacenterList(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return }
        let wrapper = object as? [String: Any]
        let rows = (object as? [[String: Any]]) ?? CloudDatacenter.listKeys.compactMap { wrapper?[$0] as? [[String: Any]] }.first ?? []
        let centers = rows.map { row -> [String: Any] in
            let id = row["dataCenter"] as? String ?? ""
            return ["id": CloudDatacenter.validName(id) ? id : "invalid", "hasAddress": !(row["publicIp"] as? String ?? "").isEmpty]
        }
        let summary: [String: Any] = ["receivedCount": rows.count, "centers": centers, "language": specification["language"] as? String ?? "", "platform": specification["platform"] as? String ?? ""]
        guard let directory = Diagnostics.directory,
              let encoded = try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? encoded.write(to: directory.appendingPathComponent("cloud-datacenters.json"), options: .atomic)
    }
    public func selectDatacenter(_ name: String, results: [CloudPingResult]) async throws -> UInt16? {
        guard let session = active, authorized, sessionKey != nil else { throw CloudProtocol.Failure.unauthorized }
        guard CloudDatacenter.validName(name) else { throw CloudDatacenter.Failure.invalidName }
        let attempt = generation
        selectedDatacenter = nil
        guard let chosen = results.first, chosen.center.id == name, results.count <= 100,
              Set(results.map(\.center.id)).count == results.count else { throw CloudProtocol.Failure.invalidResponse }
        guard chosen.rttMs != nil else { throw CloudDatacenter.Failure.unreachable }
        for result in results {
            guard CloudDatacenter.validName(result.center.id), (576...1454).contains(result.mtuIn), (576...1454).contains(result.mtuOut),
                  result.rttMs.map({ (1...60000).contains($0) }) ?? true else { throw CloudProtocol.Failure.invalidResponse }
        }
        let (data, response) = try await request(url: Self.endpoint(session, "datacenters/select"), method: "POST", body: ["requestGameSpecification": specification, "pingResults": results.map(\.json)], stage: "Datacenter selection")
        try ensureCurrent(attempt)
        try rotateKey(response)
        selectedDatacenter = name
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let network = body?["network"] as? [String: Any]
        if let value = body?["port"] ?? network?["port"] {
            guard let port = CloudAllocation.integer(value), (1...65535).contains(port) else { throw CloudProtocol.Failure.invalidResponse }
            return UInt16(port)
        }
        return UInt16(chosen.center.port)
    }
    public func allocate(network: CloudNetworkEstimate) async throws -> CloudAllocation {
        guard let session = active, authorized, sessionKey != nil, let center = selectedDatacenter else { throw CloudProtocol.Failure.unauthorized }
        let attempt = generation
        let body: [String: Any] = ["requestGameSpecification": specification, "dataCenter": center, "network": network.json,
                                   "stateExecutionTime": network.stateExecutionTimeMs, "streamTestTime": network.streamTestTimeMs]
        let (data, response) = try await request(url: Self.endpoint(session, "allocate"), method: "POST", body: body, stage: "Game server allocation")
        try ensureCurrent(attempt)
        try rotateKey(response)
        return try CloudAllocation.decode(data)
    }
    private func ensureCurrent(_ attempt: UUID) throws {
        try Task.checkCancellation()
        guard generation == attempt else { throw CloudProtocol.Failure.cancelled }
    }
    public static func readable(_ text: String?) -> String {
        let kept = (text ?? "").unicodeScalars.filter { (0x20...0x7e).contains($0.value) }
        return String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespaces).prefix(120).description
    }
    private static func validKey(_ key: String) -> Bool {
        !key.isEmpty && key.count < 16384 && !key.contains("\r") && !key.contains("\n")
    }
    private func rotateKey(_ response: HTTPURLResponse) throws {
        guard let key = response.value(forHTTPHeaderField: "X-Gaikai-Session") else { return }
        guard Self.validKey(key) else { throw CloudProtocol.Failure.invalidResponse }
        sessionKey = key
    }
    public func reset() {
        generation = UUID()
        clearSession()
    }
    private func clearSession() {
        active = nil
        lockedKey = nil
        sessionKey = nil
        authorized = false
        specification = [:]
        selectedDatacenter = nil
    }
    private static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds) * 1000 + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }
    private static func endpoint(_ session: CloudProtocol.Session, _ action: String) -> URL {
        URL(string: "https://cc.prod.gaikai.com/v1/sessions/\(session.sessionId)/\(action)")!
    }
    static func lockURL(_ session: CloudProtocol.Session, forceLogout: Bool) -> URL {
        endpoint(session, forceLogout ? "lock?forceLogout=true" : "lock?forceLogout=false")
    }
    private func request(url: URL, method: String = "GET", body: [String: Any]? = nil, stage: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(backend != .ps5 ? PSPlusPCService.userAgent : Self.portalUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        if let active { request.setValue(active.sessionId, forHTTPHeaderField: "X-Gaikai-SessionId") }
        if let sessionKey { request.setValue(sessionKey, forHTTPHeaderField: "X-Gaikai-Session") }
        let (data, response) = try await http.plainData(for: request)
        guard let response = response as? HTTPURLResponse else { throw CloudProtocol.Failure.invalidResponse }
        if let call = lockCall, url.path.hasSuffix("/lock") {
            let now = ContinuousClock.now
            lockTrace.append(CloudLockDiagnostics.entry(status: response.statusCode, data: data, headers: response.allHeaderFields, forced: call.forced, attempt: call.attempt,
                                                        elapsedMs: Self.milliseconds(call.firstStarted.duration(to: now)), requestMs: Self.milliseconds(call.started.duration(to: now))))
            if lockTrace.count > 40 { lockTrace.removeFirst(lockTrace.count - 40) }
            if recordsFailureDiagnostics { CloudLockDiagnostics.write(lockTrace) }
        }
        if recordsFailureDiagnostics {
            let received = response.value(forHTTPHeaderField: "X-Gaikai-Session")
            let action = url.path.components(separatedBy: "/").last ?? ""
            var entry: [String: Any] = ["step": action, "status": response.statusCode, "elapsedMs": Self.milliseconds(traceStart.duration(to: .now)),
                "sentKeyLength": sessionKey?.count ?? 0, "receivedKeyLength": received?.count ?? 0,
                "changed": received != nil && received != sessionKey,
                "hasComma": received?.contains(",") ?? false,
                "hasWhitespace": received?.contains(where: { $0.isWhitespace }) ?? false]
            if action == "lock" { entry["forceLogout"] = url.query == "forceLogout=true" }
            if action == "select", let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                entry["answerFields"] = ["dataCenter", "port", "network", "publicIp", "queued", "pingResults"].filter { object[$0] != nil }
            }
            if action == "allocate", let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                let known = ["launchSlot", "queued", "dataMigration", "dataMigrationPercentageComplete", "queuePosition", "displayQueuePosition", "waitTimeEstimate", "pollFrequency",
                             "handshakeKey", "launchSpecification", "sessionId", "timeLimit", "startGameTimeout", "publicIp", "privateIp", "port"]
                func shape(_ source: [String: Any]) -> [String: String] {
                    Dictionary(uniqueKeysWithValues: known.compactMap { key in source[key].map { value in (key, (value as? String).map { "string(\($0.count))" } ?? (value is NSNumber ? "number" : value is [Any] ? "array" : value is [String: Any] ? "object" : "null")) } })
                }
                entry["answerShape"] = shape(object)
                if let slot = object["launchSlot"] as? [String: Any] { entry["slotShape"] = shape(slot) }
            }
            keyTrace.append(entry)
            if let directory = Diagnostics.directory,
               let encoded = try? JSONSerialization.data(withJSONObject: keyTrace, options: [.sortedKeys]) {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? encoded.write(to: directory.appendingPathComponent("cloud-key-structure.json"), options: .atomic)
            }
        }
        guard (200..<300).contains(response.statusCode) else {
            if recordsFailureDiagnostics { CloudResponseDiagnostics.record(status: response.statusCode, data: data, response: response) }
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let event = response.value(forHTTPHeaderField: "X-Gaikai-Event").flatMap { $0.data(using: .utf8) }.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            let firstError = (object?["errors"] as? [[String: Any]])?.first ?? object?["error"] as? [String: Any]
            if response.statusCode == 403, object == nil,
               response.value(forHTTPHeaderField: "Server")?.lowercased() == "cloudfront" || response.value(forHTTPHeaderField: "X-Cache")?.lowercased().contains("cloudfront") == true {
                throw CloudProtocol.Failure.serviceEvent(403, stage, "gatewayDenied")
            }
            if let component = object?["componentCode"] as? String,
               let event = firstError?["eventCode"],
               let eventString = (event as? String) ?? (event as? NSNumber)?.stringValue,
               !component.isEmpty, component.count <= 8, !eventString.isEmpty, eventString.count <= 10,
               CloudResponseDiagnostics.numericCode(component), CloudResponseDiagnostics.numericCode(eventString) {
                throw CloudProtocol.Failure.serviceCode(response.statusCode, stage, eventString.hasPrefix(component + ".") ? eventString : component + "." + eventString,
                                                        Self.readable(firstError?["description"] as? String))
            }
            let name = (firstError?["name"] as? String) ?? (object?["name"] as? String) ?? (event?["name"] as? String) ?? ""
            if ["noGameForEntitlementId", "noGameForEntitlement", "AUTHORIZATION_FAILED", "invalidGameSpecification", "invalidRequest", "invalidAuthCode", "missingEntitlementId", "invalidRequestBody", "noAvailableDatacenter", "invalidSession", "invalidDataCenter", "noCapacity", "sessionNotLocked", "allocationFailed"].contains(name) {
                throw CloudProtocol.Failure.serviceEvent(response.statusCode, stage, name)
            }
            throw CloudProtocol.Failure.service(response.statusCode, stage)
        }
        guard data.count < 2_000_000 else { throw CloudProtocol.Failure.invalidResponse }
        return (data, response)
    }
}

final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
