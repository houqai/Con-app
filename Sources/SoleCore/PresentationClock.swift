import Foundation

public struct PresentationClock {
    public static let interval: UInt64 = 16_666_667
    public static let lead: Double = 21_000_000
    private static let later: Double = 400_000
    private static let sooner: Double = 8_000
    private static let roomy: Double = 8_000_000
    private static let brisk: Double = 80_000
    static let limit: Double = 16_000_000
    private static let moved: Double = 10_000_000
    private static let steady: Double = 4_000_000

    public var lead: Double { didSet { lead = max(0, lead) } }

    public init(lead: Double = PresentationClock.lead) { self.lead = max(0, lead) }

    private var lastFrame: Int?
    private var grid: Double?
    private var short: Double = 0
    private var pace = Pace()

    var frameInterval: Double { pace.interval }

    public mutating func timestamp(arrival: UInt64, frame: Int?, isNew: Bool = true) -> UInt64 {
        let now = Double(arrival)
        let delta: Int
        if let frame, let lastFrame {
            delta = (frame - lastFrame) & 0xffff
        } else { delta = 1 }
        lastFrame = frame
        guard let grid, delta > 0, delta <= 6 else {
            self.grid = now + lead
            short = 0
            pace.restart(at: now)
            return UInt64(now + lead)
        }
        pace.count(arrival: now, frames: delta)
        var time = grid + Double(delta) * pace.interval
        let spare = time - now - lead
        if spare > Self.limit {
            time = now + lead + Self.limit
            short = 0
        } else if spare < 0 {
            if isNew, -spare > Self.moved, abs(-spare - short) < Self.steady {
                time = now + lead
                short = 0
            } else {
                time += min(-spare, Self.later)
                if isNew { short = -spare }
            }
        } else if isNew {
            time -= min(spare, Self.sooner) + min(max(spare - Self.roomy, 0), Self.brisk)
            short = 0
        }
        self.grid = time
        return UInt64(max(time, now))
    }

    private struct Pace {
        private static let block = 128
        private static let kept = 16
        private static let baseline: Double = 1024
        var interval = Double(PresentationClock.interval)
        private var start: Double = 0
        private var frames = 0
        private var time: Double = 0
        private var position: Double = 0
        private var count = 0
        private var marks: [(position: Double, time: Double)] = []

        mutating func restart(at arrival: Double) {
            start = arrival; frames = 0
            time = 0; position = 0; count = 0
            marks = []
        }

        mutating func count(arrival: Double, frames passed: Int) {
            frames += passed
            time += arrival - start; position += Double(frames); count += 1
            guard count == Self.block else { return }
            let mark = (position: position / Double(count), time: time / Double(count))
            time = 0; position = 0; count = 0
            if let last = marks.last, abs(mark.time - last.time - (mark.position - last.position) * interval) > 12_000_000 { marks = [] }
            marks.append(mark)
            if marks.count > Self.kept { marks.removeFirst() }
            guard let first = marks.first, mark.position - first.position >= Self.baseline else { return }
            let measured = (mark.time - first.time) / (mark.position - first.position)
            let nominal = Double(PresentationClock.interval)
            if measured > nominal / 2, measured < nominal * 4 { interval = measured }
        }
    }
}
