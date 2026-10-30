import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SoleCloud
import SoleCore
import SoleEngine

@MainActor public final class CloudAuthorization {
    public init() {}
    private let service = CloudSessionService(recordsFailureDiagnostics: true)
    private let entitlements = CloudEntitlementService()
    private let pcService = PSPlusPCService()
    private var revision = UUID()
    private let http = URLSession.lasting(.ephemeral, delegate: CloudOAuthRedirectPolicy())
    private static let deviceIDKey = "sole.cloudDeviceID"
    private var deviceID: String {
        if let stored = Settings.store.string(forKey: Self.deviceIDKey),
           stored.count == 48,
           stored.allSatisfy({ $0.isASCII && $0.isHexDigit }) {
            return stored
        }
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        let value = "0000000700410080" + bytes.map { String(format: "%02x", $0) }.joined()
        Settings.store.set(value, forKey: Self.deviceIDKey)
        return value
    }
    public struct Preparation: Sendable {
        public let centers: [CloudDatacenter]
        public let latencies: [String: Int]
        public let selected: CloudDatacenter
        public let reportedLatency: Int?
        public let mtuIn: Int
        public let mtuOut: Int
        public let slot: CloudLaunchSlot
        public init(centers: [CloudDatacenter], latencies: [String: Int], selected: CloudDatacenter, reportedLatency: Int?, mtuIn: Int, mtuOut: Int, slot: CloudLaunchSlot) {
            self.centers = centers; self.latencies = latencies; self.selected = selected; self.reportedLatency = reportedLatency
            self.mtuIn = mtuIn; self.mtuOut = mtuOut; self.slot = slot
        }
    }
    public func connect(
        credential: () async throws -> String,
        entitlementID: String? = nil,
        conceptID: Int? = nil,
        title: String? = nil,
        backend: CloudBackend = .ps5,
        isPlusMember: Bool = true,
        height: Int = 1080,
        bitrateKbps: Int = 10_000,
        language: String = "en",
        preferredDatacenter: String? = nil,
        distantServers: Bool = false,
        forceLogout: Bool = false,
        onDatacenters: ([CloudDatacenter], [String: Int]) -> Void = { _, _ in },
        progress: (String) -> Void
    ) async throws -> Preparation? {
        let attempt = UUID(); revision = attempt
        let startedAt = ContinuousClock.now
        do {
            progress(loc("Connecting to PS Cloud…"))
            let sso = try await credential()
            guard SonySSO.validValue(sso) else { throw CloudProtocol.Failure.websiteSessionRequired }
            try check(attempt)
            if entitlementID == nil && conceptID == nil {
                let clients = try await service.clients()
                try check(attempt)
                progress(loc("Confirming your account with the cloud…"))
                _ = try await grant(clientID: clients.cloud, streamServer: false, sso: sso)
                try check(attempt)
                progress(loc("Confirming access to the game stream…"))
                _ = try await grant(clientID: clients.stream, streamServer: true, sso: sso)
                try check(attempt)
                return nil
            }
            progress(loc("Checking the game license…"))
            let resolvedEntitlement: String
            if backend != .ps5 {
                guard let entitlementID else { throw PSPlusPCService.Failure.unavailable }
                _ = try await pcService.catalog(sso: sso, deviceID: deviceID)
                try check(attempt)
                resolvedEntitlement = try await pcService.resolve(productID: entitlementID)
                try await pcService.ensureStreamingLicense(entitlementID: resolvedEntitlement, sso: sso, deviceID: deviceID)
            } else {
                let entitlementToken = try await commerceGrant(sso: sso)
                try check(attempt)
                resolvedEntitlement = try await entitlements.resolve(productID: entitlementID, conceptID: conceptID, title: title, token: entitlementToken)
            }
            try check(attempt)
            progress(loc("Creating the game session…"))
            let session = try await service.begin(entitlementID: resolvedEntitlement, isPlusMember: isPlusMember, height: StreamQuality.height(height, for: backend), language: language, backend: backend)
            try check(attempt)
            progress(loc("Confirming your account with the cloud…"))
            let cloud = try await streamGrant(clientID: session.gkClientId, streamServer: false, sso: sso, backend: backend)
            try check(attempt)
            progress(loc("Confirming access to the game stream…"))
            let stream = try await streamGrant(clientID: session.streamServerClientId, streamServer: true, sso: sso, backend: backend)
            try check(attempt)
            try await service.authorize(session, cloudCode: cloud, streamCode: stream)
            try check(attempt)
            progress(forceLogout ? loc("Ending the other session…") : loc("Preparing the game session…"))
            try await CloudSessionService.acquireLock(service, forceLogout: forceLogout) { seconds in
                try check(attempt)
                progress(Self.endingOtherSession(seconds: seconds))
            }
            try check(attempt)
            progress(loc("Getting the list of servers…"))
            let centers = try CloudDatacenter.decode(try await service.datacenterResponse())
            try check(attempt)
            progress(loc("Measuring latency to the servers…"))
            let probeStartedAt = ContinuousClock.now
            let probeCredential = try await service.networkProbeCredential()
            let reports = await Self.probe(centers, credential: probeCredential, packetPrefix: backend != .ps5 ? 1 : 0)
            let probeDuration = Self.milliseconds(probeStartedAt.duration(to: .now))
            try check(attempt)
            let results = centers.map { center -> CloudPingResult in
                let measured = reports[center.id]?.measurement
                return CloudPingResult(center: center, rttMs: measured?.rttMs, mtuIn: measured?.mtuIn ?? 1454, mtuOut: measured?.mtuOut ?? 1254)
            }
            let latencies = Dictionary(uniqueKeysWithValues: results.compactMap { result in result.rttMs.map { (result.center.id, $0) } })
            Self.recordProbes(centers, reports: reports, durationMs: probeDuration)
            onDatacenters(centers, latencies)
            guard let selected = CloudDatacenter.choose(centers, latencies: latencies, preferred: preferredDatacenter),
                  latencies[selected.id] != nil else {
                if reports.count < centers.count { throw CloudDatacenter.Failure.probeTimeout }
                throw CloudDatacenter.Failure.unreachable
            }
            progress(loc("Selecting server %@…", Datacenter.name(selected.id, among: centers.map(\.id))))
            if !distantServers, let ms = latencies[selected.id], ms > CloudPingPolicy.limitMs { throw CloudPingPolicy.TooFar(ms: ms) }
            let ordered = CloudPingResult.ordered(results, selected: selected.id, exclusive: preferredDatacenter == selected.id, distant: distantServers)
            let serverPort = try await service.selectDatacenter(selected.id, results: ordered) ?? UInt16(selected.port)
            try check(attempt)
            var network = CloudNetworkEstimate(port: serverPort, rttMs: ordered.first?.rttMs ?? 25)
            network.mtu = ordered.first?.mtuIn ?? 1454
            network.mtuUpstream = ordered.first?.mtuOut ?? 1254
            network.bwKbpsReceived = min(max(bitrateKbps, 5_000), 80_000)
            network.bwKbpsSent = network.bwKbpsReceived
            network.stateExecutionTimeMs = Self.milliseconds(startedAt.duration(to: .now))
            network.streamTestTimeMs = probeDuration
            let slot = try await allocate(network: network, attempt: attempt, progress: progress)
            return Preparation(centers: centers, latencies: latencies, selected: selected, reportedLatency: ordered.first?.rttMs, mtuIn: network.mtu, mtuOut: network.mtuUpstream, slot: slot)
        } catch {
            if revision == attempt { await service.reset() }
            throw error
        }
    }
    nonisolated private static func probe(_ centers: [CloudDatacenter], credential: String, packetPrefix: UInt8 = 0, deadline: TimeInterval = 90) async -> [String: CloudNetworkProbe.Report] {
        let stream = AsyncStream<(String, CloudNetworkProbe.Report)> { continuation in
            for center in centers {
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.yield((center.id, CloudNetworkProbe.run(host: center.publicIp, port: UInt16(center.port), credential: credential, packetPrefix: packetPrefix)))
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + deadline) { continuation.finish() }
        }
        var reports: [String: CloudNetworkProbe.Report] = [:]
        for await (id, report) in stream {
            reports[id] = report
            if reports.count == centers.count { break }
        }
        return reports
    }
    nonisolated static func probeRecord(_ centers: [CloudDatacenter], reports: [String: CloudNetworkProbe.Report], durationMs: Double) -> [String: Any] {
        let rows = centers.map { center -> [String: Any] in
            var row: [String: Any] = ["dataCenter": center.id, "stage": reports[center.id]?.stage ?? -1, "status": reports[center.id]?.status ?? -1, "completed": reports[center.id] != nil]
            if let measured = reports[center.id]?.measurement { row["rttMs"] = measured.rttMs; row["mtuIn"] = measured.mtuIn; row["mtuOut"] = measured.mtuOut }
            if let stage = reports[center.id]?.engineStage { row["engineStage"] = stage }
            return row
        }
        return ["durationMs": Int(durationMs), "datacenters": rows]
    }
    nonisolated private static func recordProbes(_ centers: [CloudDatacenter], reports: [String: CloudNetworkProbe.Report], durationMs: Double) {
        Diagnostics.write(probeRecord(centers, reports: reports, durationMs: durationMs), named: "cloud-probe.json")
    }
    private func allocate(network: CloudNetworkEstimate, attempt: UUID, progress: (String) -> Void) async throws -> CloudLaunchSlot {
        var deadline: ContinuousClock.Instant?
        var primingRetries = 0
        while true {
            progress(loc("Requesting a game server…"))
            let allocation: CloudAllocation
            do { allocation = try await service.allocate(network: network) }
            catch CloudProtocol.Failure.serviceCode(_, _, "002.2008", _) where primingRetries < 9 {
                primingRetries += 1
                progress(loc("Sony is preparing the server after the last session…"))
                try await Task.sleep(nanoseconds: 10_000_000_000)
                try check(attempt)
                continue
            }
            switch allocation {
            case .ready(let slot):
                return slot
            case .queued(let position, let estimate, let frequency):
                try await waitInQueue(estimate: estimate, frequency: frequency, position: position, deadline: &deadline, attempt: attempt) {
                    let place = position.map { loc("position %@", $0) } ?? loc("waiting")
                    let wait = estimate.map { loc(", about %@ min", max(1, ($0 + 59) / 60)) } ?? ""
                    progress(loc("Sony queue: %@%@…", place, wait))
                }
            case .migrating(let percent, let frequency):
                try await waitInQueue(estimate: nil, frequency: frequency, position: nil, deadline: &deadline, attempt: attempt) {
                    progress(loc("Sony is moving your saves to the server") + (percent.map { ": \($0)%" } ?? "") + "…")
                }
            }
        }
    }
    private func waitInQueue(estimate: Int?, frequency: Int, position: Int?, deadline: inout ContinuousClock.Instant?, attempt: UUID, report: () -> Void) async throws {
        try check(attempt)
        let now = ContinuousClock.now
        let limit = deadline ?? now.advanced(by: .milliseconds(Int64(CloudQueuePolicy.deadline(estimate: estimate) * 1000)))
        deadline = limit
        let interval = CloudQueuePolicy.pollInterval(frequency)
        guard now.advanced(by: .milliseconds(Int64(interval * 1000))) < limit else { throw CloudAllocation.Failure.queueTimeout(position: position) }
        report()
        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        try check(attempt)
    }
    nonisolated static func endingOtherSession(seconds: Int) -> String {
        loc("Ending the other session… (%@ s)", String(max(1, seconds)))
    }
    private static func milliseconds(_ duration: Duration) -> Double {
        let value = duration.components
        return Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15
    }
    private func check(_ attempt: UUID) throws {
        try Task.checkCancellation()
        guard revision == attempt else { throw CloudProtocol.Failure.cancelled }
    }
    public func cancel() {
        let cancellation = UUID(); revision = cancellation
        Task { guard revision == cancellation else { return }; await service.reset() }
    }
    public func ownedTitles(credential: () async throws -> String) async throws -> [CloudEntitlementService.OwnedTitle] {
        let sso = try await credential()
        guard SonySSO.validValue(sso) else { throw CloudProtocol.Failure.websiteSessionRequired }
        return try await entitlements.owned(token: try await commerceGrant(sso: sso), includePS4: true)
    }
    private func commerceGrant(sso: String) async throws -> String {
        let state = UUID().uuidString + UUID().uuidString
        let url = try CloudEntitlementService.authorizationURL(state: state, deviceID: deviceID)
        let callback = try await authorizationRedirect(url, sso: sso, named: loc("Game licenses"), otherwise: loc("Game license check"))
        return try CloudEntitlementService.token(from: callback, expectedState: state)
    }
    private func authorizationRedirect(_ url: URL, sso: String, named: @autoclosure () -> String, otherwise: @autoclosure () -> String) async throws -> URL {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue(CloudSessionService.portalUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("npsso=" + sso, forHTTPHeaderField: "Cookie")
        let (data, response) = try await http.plainData(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw CloudProtocol.Failure.invalidResponse }
        guard (300..<400).contains(response.statusCode),
              let location = response.value(forHTTPHeaderField: "Location"),
              let callback = URL(string: location) else {
            throw Self.refusal(status: response.statusCode, body: data, named: named(), otherwise: otherwise())
        }
        return callback
    }
    nonisolated static func refusal(status: Int, body: Data, named: String, otherwise: String) -> CloudProtocol.Failure {
        let answer = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        if let reason = answer.flatMap(CloudProtocol.refusalReason) { return .grant(named, reason) }
        if status == 403, answer == nil { return .serviceEvent(403, otherwise, "gatewayDenied") }
        return .service(status, otherwise)
    }
    public func clearPCCatalog() async { await pcService.reset() }
    public func pcScreenshots(productID: String) async throws -> [URL] { try await pcService.screenshots(productID: productID) }
    public func pcTitles(force: Bool = false, credential: () async throws -> String) async throws -> [PSPlusPCService.Title] {
        let sso = try await credential()
        return try await pcService.catalog(sso: sso, deviceID: deviceID, force: force)
    }
    private func streamGrant(clientID: String, streamServer: Bool, sso: String, backend: CloudBackend) async throws -> String {
        if backend == .ps5 { return try await grant(clientID: clientID, streamServer: streamServer, sso: sso) }
        let scope: String
        if !streamServer {
            scope = "kamaji:commerce_native versa:user_update_entitlements_first_play kamaji:lists"
        } else if backend == .ps3 {
            scope = "kamaji:commerce_native"
        } else {
            scope = "sso:none"
        }
        return try await pcService.grant(sso: sso, deviceID: deviceID, clientID: clientID, scope: scope, omitDeviceID: backend == .ps3 && streamServer)
    }
    private func grant(clientID: String, streamServer: Bool, sso: String) async throws -> String {
        let state = UUID().uuidString + UUID().uuidString
        let url = try CloudProtocol.authorizationURL(clientID: clientID, streamServer: streamServer, state: state, deviceID: deviceID)
        let callback = try await authorizationRedirect(url, sso: sso, named: streamServer ? loc("Game stream") : loc("PS Cloud account"), otherwise: loc("PS Cloud connection"))
        return try CloudProtocol.code(from: callback, expectedState: state)
    }
}
private final class CloudOAuthRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
