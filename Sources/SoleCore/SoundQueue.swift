import Foundation

public struct SoundQueue: Sendable {
    public struct Stats: Sendable {
        public var received = 0
        public var nonSilent = 0
        public var scheduled = 0
        public var played = 0
        public var restarts = 0
        public var errors = 0
        public var pending = 0
        public init() {}
    }
    private var counts = Stats()
    private var format: (channels: Int, rate: Int)?
    private var pending = 0
    private var lastProgress: TimeInterval = 0
    private var generation = 0
    public init() {}

    public var stats: Stats { var result = counts; result.pending = pending; return result }
    public static let capacity = 8

    public static func accepts(samples: Int, channels: Int, rate: Int) -> Bool {
        (1...8).contains(channels) && (8000...192000).contains(rate) && samples > 0 && samples % channels == 0 && samples <= 5760 * channels
    }
    public static func isAudible(_ samples: some Sequence<Int16>) -> Bool { samples.contains(where: { $0 > 64 || $0 < -64 }) }

    public mutating func arrived(audible: Bool, channels: Int, rate: Int, outputAlive: Bool, now: TimeInterval) -> Bool {
        counts.received += 1
        if audible { counts.nonSilent += 1 }
        let stalled = pending > 0 && now - lastProgress > 0.25
        let same = format.map { $0.channels == channels && $0.rate == rate } ?? false
        guard !same || !outputAlive || stalled else { return false }
        if format != nil { counts.restarts += 1 }
        reset(now: now)
        return true
    }
    public mutating func started(channels: Int, rate: Int) { format = (channels, rate) }
    public mutating func startFailed() { format = nil; counts.errors += 1 }

    public var hasRoom: Bool { pending < Self.capacity && format != nil }
    public mutating func schedule(now: TimeInterval) -> Int {
        if pending == 0 { lastProgress = now }
        pending += 1
        counts.scheduled += 1
        return generation
    }
    public mutating func played(mark: Int, now: TimeInterval) {
        guard mark == generation else { return }
        pending = max(0, pending - 1)
        counts.played += 1
        lastProgress = now
    }

    public mutating func reset(now: TimeInterval) { generation += 1; pending = 0; lastProgress = now }
    public mutating func startOver(now: TimeInterval) -> Bool {
        guard format != nil else { return false }
        reset(now: now)
        format = nil
        return true
    }
    public mutating func stop(now: TimeInterval) { reset(now: now); format = nil; counts = Stats() }
}
