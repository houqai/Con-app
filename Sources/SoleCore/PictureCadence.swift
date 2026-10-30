import Foundation

public struct PictureCadence: Sendable {
    static let identical = 0.06
    static let ratio = 0.45
    static let window = 8
    static let contrast = 2.2
    static let awake = 3.0
    static let cut = 8.0
    private var previous = 0.0
    private var recent: [Double] = []
    private var halved = false
    private var sinceNew = 0
    private var repeatLevel = 0.0

    public init() {}

    public mutating func isNew(change: Double) -> Bool {
        defer { previous = change }
        sinceNew += 1
        if change >= Self.cut { recent = [] } else { recent.append(change) }
        if recent.count > Self.window { recent.removeFirst() }
        var halves: (this: Double, other: Double, apart: Bool)?
        if recent.count == Self.window {
            var this: [Double] = [], other: [Double] = []
            for (age, value) in recent.reversed().enumerated() {
                if age % 2 == 0 { this.append(value) } else { other.append(value) }
            }
            let apart = this.min()! > other.max()! || other.min()! > this.max()!
            halves = (Self.median(this), Self.median(other), apart)
        }
        if let (this, other, apart) = halves {
            let stronger = max(this, other), weaker = min(this, other)
            if halved {
                if weaker > Self.awake * repeatLevel, weaker >= Self.identical { halved = false }
            } else if apart, stronger >= Self.contrast * max(weaker, Self.identical / 2), stronger >= 2 * Self.identical {
                halved = true
                repeatLevel = weaker
                sinceNew = this >= other ? 2 : 1
            }
        }
        let new: Bool
        if halved {
            var here = sinceNew >= 2
            var clear = false
            if let (this, other, apart) = halves, apart {
                if this > Self.contrast * other { here = true; clear = true } else if other > Self.contrast * this { here = false; clear = true }
            }
            new = here && change >= Self.identical
            if !new, clear { repeatLevel += (change - repeatLevel) / 4 }
        } else {
            new = change >= Self.identical && (previous == 255 || change >= previous * Self.ratio)
        }
        if new { sinceNew = 0 }
        return new
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted(), middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    public static func change(from previous: [UInt8], to current: [UInt8]) -> Double {
        guard !current.isEmpty, previous.count == current.count else { return 255 }
        var sum = 0
        current.withUnsafeBufferPointer { now in
            previous.withUnsafeBufferPointer { before in
                for index in 0..<now.count { sum += abs(Int(now[index]) - Int(before[index])) }
            }
        }
        return Double(sum) / Double(current.count)
    }
}
