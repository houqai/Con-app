import Foundation
import SoleCore

public enum StreamPanel {
    public enum Detail: Sendable { case full, less, least }
    public enum Trouble: Sendable {
        case none, some, broken
        public var color: (red: Double, green: Double, blue: Double) {
            switch self {
            case .none: return (93 / 255.0, 202 / 255.0, 165 / 255.0)
            case .some: return (1, 159 / 255.0, 10 / 255.0)
            case .broken: return (1, 84 / 255.0, 77 / 255.0)
            }
        }
    }
    public enum Kind: String, Sendable {
        case frames, ping, bitrate, video
        public var icon: String {
            switch self {
            case .frames: return "film"
            case .ping: return "wifi"
            case .bitrate: return "arrow.down"
            case .video: return "tv"
            }
        }
    }
    public struct Cell: Equatable, Sendable {
        public let kind: Kind
        public let value: String
        public let unit: String?
        public let trouble: Trouble
        public init(_ kind: Kind, _ value: String, _ unit: String? = nil, trouble: Trouble = .none) {
            self.kind = kind; self.value = value; self.unit = unit; self.trouble = trouble
        }
    }

    public static func cells(_ stats: StreamStats, detail: Detail) -> [Cell] {
        var cells = [Cell(.frames, rate(stats.shownPerSecond), stats.generatedNote)]
        let ping = stats.livePingMs ?? stats.measuredPingMs
        cells.append(Cell(.ping, ping.map(String.init) ?? "—", ping == nil ? nil : loc("ms"), trouble: stats.trouble))
        if detail == .full { cells.append(Cell(.bitrate, String(format: "%.1f", stats.bitrateMbps), loc("Mbps"))) }
        if detail != .least { cells.append(Cell(.video, stats.videoSize)) }
        return cells
    }

    public static func summary(_ stats: StreamStats) -> String {
        var parts = ["\(rate(stats.shownPerSecond)) \(stats.framesNote)", "\(String(format: "%.1f", stats.bitrateMbps)) \(loc("Mbps"))"]
        if let ping = stats.livePingMs { parts.append("\(loc("ping")) \(ping) \(loc("ms"))") }
        else if let ping = stats.measuredPingMs { parts.append("\(loc("ping at start")) \(ping) \(loc("ms"))") }
        if let delay = stats.delayMs { parts.append("\(loc("delay")) ≈\(delay) \(loc("ms"))") }
        parts.append("\(loc("decoder")) \(String(format: "%.1f", stats.decodeMs)) \(loc("ms"))")
        parts.append("\(stats.videoSize) \(stats.codec.hasPrefix("H.265") ? "H.265" : "H.264")")
        if let city = stats.serverCity { parts.append(city) }
        return parts.joined(separator: " · ")
    }

    static func rate(_ value: Double) -> String { String(Int(value.rounded())) }
}

extension StreamStats {
    public var trouble: StreamPanel.Trouble {
        if recentFailures > 0 || recentLostFrames >= 30 { return .broken }
        return recentLostFrames > 0 ? .some : .none
    }
    public var repeats: Bool { newPerSecond >= max(10, framesPerSecond * 0.35) && framesPerSecond - newPerSecond > 6 }
    private var generated: Double { generation == .active ? generatedPerSecond : 0 }
    public var generatedNote: String? { generated > 0 ? "+" + StreamPanel.rate(generated) : nil }
    public var shownPerSecond: Double { (repeats ? newPerSecond : framesPerSecond) + generated }
    public var framesNote: String {
        if generated > 0 { return loc("fps · +%@ generated", StreamPanel.rate(generated)) }
        switch generation {
        case .standby: return loc("fps · generation not needed")
        case .unavailable: return loc("fps · generation unavailable")
        default: return repeats ? loc("fps · stream %@", StreamPanel.rate(framesPerSecond)) : loc("fps")
        }
    }
    public var videoSize: String {
        guard height > 0 else { return "—" }
        func name(_ height: Int) -> String { height == 4320 ? "8K" : StreamQuality.name(height: height) }
        return upscaledHeight > 0 ? "\(name(height))→\(name(upscaledHeight))" : name(height)
    }
    public var serverCity: String? { server.map { $0.components(separatedBy: ",").first ?? $0 } }
    public var facts: [String] { (serverCity.map { [$0] } ?? []) + (height > 0 ? ["\(height)p"] : []) }
}

extension Upscale.Amount {
    public var title: String {
        "×\(rawValue)"
    }
}

extension Upscale.Method {
    public var title: String {
        switch self {
        case .fsr: return "FSR 1"
        case .nis: return "NIS"
        case .anime4k: return "Anime4K"
        case .metalFX: return "MetalFX"
        }
    }
}

extension StreamMenu.Item {
    public func title(fullScreen: Bool) -> String {
        switch self {
        case .restart: return loc("Restart game")
        case .resume: return loc("Resume")
        case .stats: return loc("Stream stats")
        case .generation: return loc("Frame generation")
        case .upscaler: return loc("Upscaler")
        case .upscaleAmount: return loc("Enlargement")
        case .upscaleMethod: return loc("Upscaling method")
        case .fullScreen: return fullScreen ? loc("Exit full screen") : loc("Full screen")
        case .leave: return loc("Close game")
        }
    }
    public func isOn(statsVisible: Bool, generation: Bool, upscaling: Bool = false) -> Bool? {
        switch self {
        case .stats: return statsVisible
        case .generation: return generation
        case .upscaler: return upscaling
        default: return nil
        }
    }
    public static func stateText(_ on: Bool) -> String { on ? loc("On") : loc("Off") }
    public func value(upscaleAmount: Upscale.Amount, upscaleMethod: Upscale.Method) -> String? {
        switch self {
        case .upscaleAmount: return upscaleAmount.title
        case .upscaleMethod: return upscaleMethod.title
        default: return nil
        }
    }
}

extension GenerationState {
    public static func heightChoices(offered: [Int], chosen: Int) -> [(height: Int, title: String)] {
        (offered.contains(chosen) ? offered : offered + [chosen]).sorted().map { height in
            (height, height == defaultHeight ? loc("720p · faster") : StreamQuality.name(height: height))
        }
    }
}

extension Game {
    public static func genreName(_ code: String) -> String {
        let names = ["ACTION": loc("Action"), "ADVENTURE": loc("Adventure"), "ROLE_PLAYING_GAMES": loc("Role-playing"), "SPORTS": loc("Sports"),
                     "RACING": loc("Racing"), "FIGHTING": loc("Fighting"), "PUZZLE": loc("Puzzle"), "HORROR": loc("Horror"),
                     "SIMULATOR": loc("Simulation"), "STRATEGY": loc("Strategy")]
        return names[code] ?? code.capitalized.replacingOccurrences(of: "_", with: " ")
    }

    public var hue: Double {
        let title = title.lowercased()
        let known: [(String, Double)] = [("demon", 250), ("mortal", 30), ("cyberpunk", 100), ("valhalla", 215), ("fortnite", 290), ("redacted", 95),
                                         ("dragon", 20), ("hogwarts", 305), ("war thunder", 195), ("wuthering", 60), ("xcom", 15)]
        for (name, hue) in known where title.contains(name) { return hue }
        return Double(id.utf8.reduce(0) { ($0 * 31 + Int($1)) % 360 })
    }
}
