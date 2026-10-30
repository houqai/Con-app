import Foundation
import SoleCore

public struct StreamStats: Equatable, Sendable {
    public var audioReceived = 0
    public var audioNonSilent = 0
    public var audioPlayed = 0
    public var audioRestarts = 0
    public var audioErrors = 0
    public var hapticPackets = 0
    public var hapticPlayed = 0
    public var triggerPackets = 0
    public var width = 0
    public var height = 0
    public var upscaledHeight = 0
    public var codec = ""
    public var framesPerSecond = 0.0
    public var submittedPerSecond = 0.0
    public var newPerSecond = 0.0
    public var generatedPerSecond = 0.0
    public var generation = GenerationState.off
    public var bitrateMbps = 0.0
    public var decodeMs = 0.0
    public var decodeFailures = 0
    public var lostFrames = 0
    public var recentLostFrames = 0
    public var recentFailures = 0
    public var bridgedLosses = 0
    public var hiddenFrames = 0
    public var hiddenRuns = 0
    public var addedDelayMs = 0.0
    public var seconds = 0
    public var server: String?
    public var measuredPingMs: Int?
    public var reportedPingMs: Int?
    public var livePingMs: Int?
    public var displayHz = 0
    public var screenDelayMs = 0.0
    public var prepareQueueMs = 0.0, deliveryMs = 0.0, maxDeliveryMs = 0.0
    public var presentationMs = 0.0
    public var queueDrops = 0
    public var delayMs: Int? { (livePingMs ?? measuredPingMs).map { $0 + Int(screenDelayMs.rounded()) } }
    public init() {}

    public var health: [String: Any] {
        ["codec": codec, "width": width, "height": height,
         "audioReceived": audioReceived, "audioNonSilent": audioNonSilent, "audioPlayed": audioPlayed,
         "audioErrors": audioErrors, "audioRestarts": audioRestarts,
         "receivedFPS": framesPerSecond, "shownFPS": submittedPerSecond,
         "prepareQueueMs": prepareQueueMs, "deliveryMs": deliveryMs, "maxDeliveryMs": maxDeliveryMs, "queueDrops": queueDrops,
         "lostFrames": lostFrames, "recentLostFrames": recentLostFrames, "decodeFailures": decodeFailures,
         "hiddenFrames": hiddenFrames, "hiddenRuns": hiddenRuns,
         "decodeMs": decodeMs, "presentationMs": presentationMs, "addedDelayMs": addedDelayMs,
         "screenDelayMs": screenDelayMs, "displayHz": displayHz,
         "newFPS": newPerSecond, "generatedFPS": generatedPerSecond, "generation": "\(generation)", "upscaledHeight": upscaledHeight]
    }
}

public struct StreamMeter: Sendable {
    public struct Reading: Sendable {
        public var video = VideoStats()
        public var audioReceived = 0, audioNonSilent = 0, audioPlayed = 0, audioRestarts = 0, audioErrors = 0
        public var hapticPackets = 0, hapticPlayed = 0, triggerPackets = 0
        public var roundTrip: (milliseconds: Double, count: UInt64)?
        public var hidden: (frames: Int, runs: Int)?
        public var displayHz = 0
        public var askedHEVC = false
        public init() {}
    }
    private let server: String?, measuredPingMs: Int?, reportedPingMs: Int?
    private var started: TimeInterval?
    private var last: (time: TimeInterval, received: Int, shown: Int, new: Int, generated: Int, bytes: Int)?
    private var rates: StreamStats?
    private var pings: [Double] = []
    private var pingCount: UInt64 = 0
    private var losses: [(lost: Int, failures: Int)] = []

    public init(server: String? = nil, measuredPingMs: Int? = nil, reportedPingMs: Int? = nil) {
        self.server = server; self.measuredPingMs = measuredPingMs; self.reportedPingMs = reportedPingMs
    }

    static func codecName(_ code: UInt32, askedHEVC: Bool) -> String {
        switch code {
        case 0x68766331, 0x68657631: return "H.265 (HEVC)"
        case 0x61766331: return "H.264 (AVC)"
        default: return askedHEVC ? "H.265 (HEVC)" : "H.264 (AVC)"
        }
    }

    public mutating func sample(_ reading: Reading, at time: TimeInterval) -> StreamStats {
        let video = reading.video
        var next = StreamStats()
        next.audioReceived = reading.audioReceived; next.audioNonSilent = reading.audioNonSilent; next.audioPlayed = reading.audioPlayed
        next.audioRestarts = reading.audioRestarts; next.audioErrors = reading.audioErrors
        next.hapticPlayed = reading.hapticPlayed; next.hapticPackets = reading.hapticPackets; next.triggerPackets = reading.triggerPackets
        next.width = video.width; next.height = video.height; next.upscaledHeight = video.upscaledHeight
        next.codec = Self.codecName(video.codec, askedHEVC: reading.askedHEVC)
        next.generation = video.generation; next.addedDelayMs = video.addedDelayMs
        next.decodeMs = video.decodeMs; next.decodeFailures = video.decodeFailures
        next.lostFrames = video.missingFrames; next.bridgedLosses = video.bridgedLosses
        next.hiddenFrames = reading.hidden?.frames ?? video.hiddenFrames; next.hiddenRuns = reading.hidden?.runs ?? 0
        if let before = losses.first {
            next.recentLostFrames = video.missingFrames - before.lost; next.recentFailures = video.decodeFailures - before.failures
        }
        losses = Array((losses + [(video.missingFrames, video.decodeFailures)]).suffix(6))
        let started = self.started ?? time
        self.started = started
        next.seconds = Int(time - started)
        next.server = server; next.measuredPingMs = measuredPingMs; next.reportedPingMs = reportedPingMs
        if let trip = reading.roundTrip, trip.count != pingCount {
            pingCount = trip.count
            pings = Array((pings + [trip.milliseconds]).suffix(5))
        }
        if !pings.isEmpty { next.livePingMs = Int(pings.sorted()[pings.count / 2].rounded()) }
        next.displayHz = reading.displayHz
        next.prepareQueueMs = video.prepareQueueMs; next.deliveryMs = video.deliveryMs; next.maxDeliveryMs = video.maxDeliveryMs; next.queueDrops = video.queueDrops
        next.screenDelayMs = video.screenDelayMs(displayRate: Double(reading.displayHz))
        next.presentationMs = video.presentationMs
        if let last, time - last.time > 0.1 {
            let interval = time - last.time
            next.framesPerSecond = Double(video.receivedFrames - last.received) / interval
            next.submittedPerSecond = Double(video.shownFrames - last.shown + video.generatedFrames - last.generated) / interval
            next.newPerSecond = Double(video.newFrames - last.new) / interval
            next.generatedPerSecond = Double(video.generatedFrames - last.generated) / interval
            next.bitrateMbps = Double(video.bytes - last.bytes) * 8 / interval / 1_000_000
        } else if let rates {
            next.framesPerSecond = rates.framesPerSecond; next.submittedPerSecond = rates.submittedPerSecond; next.newPerSecond = rates.newPerSecond
            next.generatedPerSecond = rates.generatedPerSecond; next.bitrateMbps = rates.bitrateMbps
        }
        last = (time, video.receivedFrames, video.shownFrames, video.newFrames, video.generatedFrames, video.bytes)
        rates = next
        return next
    }
}

public struct SilentSoundWatch: Sendable {
    public enum Change: Equatable, Sendable { case none, silent, sound }
    public static let seconds: TimeInterval = 30
    private var firstFrame: TimeInterval?
    public private(set) var silent = false
    private var hasHeardSound = false
    public init() {}
    public mutating func update(received: Int, heard frames: Int, at time: TimeInterval) -> Change {
        if frames > 0 {
            defer { hasHeardSound = true; silent = false }
            return silent ? .sound : .none
        }
        guard !hasHeardSound, !silent, received > 0 else { return .none }
        let first = firstFrame ?? time
        firstFrame = first
        guard time - first >= Self.seconds else { return .none }
        silent = true
        return .silent
    }
}
