import Foundation
import SoleCloud
import SoleCore

public enum StreamQuality {
    public static let heights = [360, 540, 720, 1080, 1440, 2160]
    public static let lowestBitrate = 5.0, highestBitrate = 80.0
    public static func clampedBitrate(_ rate: Double) -> Double { min(highestBitrate, max(lowestBitrate, rate)) }
    public static func name(height: Int) -> String { height == 2160 ? "4K" : "\(height)p" }
    public static func note(height: Int) -> String {
        [360: loc("Minimum"), 540: loc("Weak network"), 720: loc("Economy"), 1080: loc("Balanced"), 1440: loc("Sharp"), 2160: loc("Maximum")][height] ?? ""
    }
    public static func bitrate(height: Int) -> Double {
        [360: 5, 540: 8, 720: 10, 1080: 30, 1440: 40, 2160: 50][height] ?? 30
    }
    public static func height(_ chosen: Int, for backend: CloudBackend) -> Int {
        backend == .ps5 ? chosen : min(chosen, backend == .ps3 ? 720 : 1080)
    }
}
