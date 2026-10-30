import Foundation
import SoleCloud
import SoleCore
import SoleEngine

public struct StreamGame: Equatable, Sendable {
    public var title: String
    public var platform: String
    public var artwork: URL?
    public init(title: String, platform: String, artwork: URL? = nil) { self.title = title; self.platform = platform; self.artwork = artwork }
    public static let unknownTitle = "PS Cloud"
}

public struct CloudStream: Sendable {
    public let slot: CloudStreamSlot
    public let title: String
    public let resolution: Int
    public let server: String
    public let measuredPingMs: Int?
    public let reportedPingMs: Int?
    public let game: StreamGame?
    public let status: String

    public init(slot: CloudStreamSlot, title: String, resolution: Int, server: String, measuredPingMs: Int?, reportedPingMs: Int?, game: StreamGame?, status: String) {
        self.slot = slot; self.title = title; self.resolution = resolution; self.server = server
        self.measuredPingMs = measuredPingMs; self.reportedPingMs = reportedPingMs; self.game = game; self.status = status
    }

    public init(_ preparation: CloudAuthorization.Preparation, game: Game?, height: Int) {
        let backend = game?.cloudBackend ?? .ps5
        let measured = preparation.latencies[preparation.selected.id]
        slot = CloudStreamSlot(
            host: preparation.slot.publicIp, port: UInt16(preparation.slot.port), packetPrefix: preparation.slot.psnWrapperType ?? 0,
            launchSpecification: preparation.slot.launchSpecification, sessionID: preparation.slot.sessionId, handshakeKey: preparation.slot.handshakeKey,
            mtuIn: preparation.mtuIn, mtuOut: preparation.mtuOut, rttMs: measured ?? 25, isPS5: game?.cloudBackend == .ps5)
        title = game.map { $0.title + " · " + $0.cloudBackend.console } ?? StreamGame.unknownTitle
        resolution = StreamQuality.height(height, for: backend)
        server = Datacenter.name(preparation.selected.id, among: preparation.centers.map(\.id))
        measuredPingMs = measured
        reportedPingMs = preparation.reportedLatency
        self.game = game.map { StreamGame(title: $0.title, platform: $0.cloudBackend.console, artwork: $0.artworkURL) }
        var ping = measured.map { loc(", %@ ms", $0) } ?? ""
        if let measured, let reported = preparation.reportedLatency, reported != measured { ping += loc(" (%@ ms reported to Sony)", reported) }
        status = loc("Server: %@%@.", server, ping)
    }
}
