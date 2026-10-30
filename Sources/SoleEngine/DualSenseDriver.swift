import Foundation

public struct DualSenseDriver: Sendable {
    public var bluetooth = false
    public private(set) var active = false
    private var retained = DualSenseReport()
    private var rumbleMode = true
    private var hapticIntensity: UInt8 = 0
    private var triggerIntensity: UInt8 = 0
    public private(set) var lastRumble: UInt64 = 0
    private static let triggersOff: [UInt8] = [0x05] + [UInt8](repeating: 0, count: 10)
    private static var motorsOff: DualSenseReport {
        var report = DualSenseReport()
        report.rumble(left: 0, right: 0)
        return report
    }
    public init() {}

    public mutating func beginSession() {
        retained = DualSenseReport(); hapticIntensity = 0; triggerIntensity = 0; lastRumble = 0
        retained.light(red: 0, green: 0, blue: 0)
    }
    public mutating func start() { active = true }

    public func greeting() -> [DualSenseReport] {
        var reset = DualSenseReport(); reset.effects[1] = 0x08
        return [reset, retained]
    }

    public mutating func intensity(trigger: Bool, value: UInt32) -> (report: DualSenseReport?, stopsHaptics: Bool) {
        if trigger {
            triggerIntensity = [0: 0xf0, 1: 0, 2: 0x60, 3: 0x90][value] ?? 0
        } else {
            hapticIntensity = [0: 0x0f, 1: 0, 2: 2, 3: 3][value] ?? 0
        }
        var report = DualSenseReport()
        if trigger, triggerIntensity == 0xf0 { report.triggers(left: Self.triggersOff, right: Self.triggersOff) }
        let off = !trigger && hapticIntensity == 0x0f
        if off { report.rumble(left: 0, right: 0) }
        return (active ? report : nil, off)
    }

    public mutating func send(_ report: DualSenseReport, now: UInt64) -> DualSenseReport? {
        if report.effects[0] & 0x0c != 0 {
            retained.triggers(left: Array(report.effects[21..<32]), right: Array(report.effects[10..<21]))
        }
        if report.effects[1] & 0x04 != 0 { retained.led(red: report.effects[44], green: report.effects[45], blue: report.effects[46]) }
        if report.effects[1] & 0x10 != 0 { retained.effects[1] |= 0x10; retained.effects[43] = report.effects[43] }
        guard active else { return nil }
        if report.effects[0] & 0x03 == 0x03 { lastRumble = now }
        return report
    }

    public func outgoing(_ report: DualSenseReport) -> DualSenseReport {
        var report = report
        report.effects[1] |= 0x40
        report.effects[36] = hapticIntensity | triggerIntensity
        if triggerIntensity == 0xf0, report.effects[0] & 0x0c != 0 {
            report.triggers(left: Self.triggersOff, right: Self.triggersOff)
        }
        return report
    }
    public mutating func wrote(_ outgoing: DualSenseReport, succeeded: Bool) {
        rumbleMode = succeeded ? outgoing.selectsRumble : true
    }

    public var playsHaptics: Bool { active && hapticIntensity != 0x0f }
    public var returnToHaptics: DualSenseReport? { rumbleMode ? DualSenseReport() : nil }
    public mutating func rumble(for pcm: Data, now: UInt64) -> DualSenseReport? {
        guard now - lastRumble >= 16_000_000, pcm.count >= 4 else { return nil }
        lastRumble = now
        let bytes = [UInt8](pcm)
        var levels = [Float](repeating: 0, count: 2)
        for offset in stride(from: 0, to: bytes.count - 3, by: 4) {
            for channel in 0..<2 {
                let i = offset + channel * 2
                let sample = Int16(bitPattern: UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8)
                levels[channel] += abs(Float(sample)) / 32768
            }
        }
        let frames = Float(bytes.count / 4)
        var report = DualSenseReport()
        report.rumble(left: UInt8(min(255, levels[0] / frames * 510)), right: UInt8(min(255, levels[1] / frames * 510)))
        return report
    }
    public static let rumbleLength = 0.08
    public func rest(afterRumbleAt time: UInt64) -> DualSenseReport? {
        guard active, lastRumble == time else { return nil }
        return Self.motorsOff
    }

    public func silence() -> DualSenseReport? {
        guard active else { return nil }
        return Self.motorsOff
    }
    public mutating func stop() -> DualSenseReport {
        active = false
        var report = Self.motorsOff
        report.triggers(left: Self.triggersOff, right: Self.triggersOff)
        return report
    }
}
