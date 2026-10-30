import Foundation
import SoleCore
import SoleEngine

public enum StreamPhase: Equatable, Sendable {
    case idle
    case registering(hostID: String)
    case connecting(hostID: String)
    case streaming(hostID: String)
    case failed(String)

    public static let cloudHostID = "ps-cloud"
    public var isLive: Bool {
        switch self { case .connecting, .streaming: return true; default: return false }
    }
    public var isBusy: Bool {
        switch self { case .registering, .connecting, .streaming: return true; default: return false }
    }
    public var isCloud: Bool { self == .connecting(hostID: Self.cloudHostID) || self == .streaming(hostID: Self.cloudHostID) }
}

public enum StreamText {
    public static func registrationPIN(_ text: String) -> UInt32? {
        let digits = text.filter(\.isNumber)
        return digits.count == 8 ? UInt32(digits) : nil
    }
    public static func describe(_ error: Error) -> String {
        switch error {
        case EngineError.invalidCredentials: return loc("The registration data is not valid. Register the console again.")
        case EngineError.cancelled: return loc("Operation cancelled.")
        case EngineError.engine(_, let message): return message.isEmpty ? loc("Engine error.") : loc(message)
        default: return loc("The Remote Play operation failed.")
        }
    }
    public static func quitReason(_ reason: String) -> String {
        for name in quitNames where reason == name || reason.hasPrefix(name + ": ") {
            return (quitName(name) ?? name) + reason.dropFirst(name.count)
        }
        return reason
    }
    static let quitNames = ["Stopped", "Session request: unknown error", "Session request: connection refused", "Session request: remote play in use", "Session request: remote play crashed", "Session request: version mismatch", "Control: unknown error", "Control: connect failed", "Control: connection refused", "Stream: unknown error", "Stream: remote disconnected", "Stream: remote shut down", "PSN registration failed"].sorted { $0.count > $1.count }
    static func quitName(_ name: String) -> String? {
        switch name {
        case "Stopped": return loc("Stopped")
        case "Session request: unknown error": return loc("Session request: unknown error")
        case "Session request: connection refused": return loc("Session request: the console refused the connection")
        case "Session request: remote play in use": return loc("Session request: Remote Play is already in use")
        case "Session request: remote play crashed": return loc("Session request: Remote Play crashed on the console")
        case "Session request: version mismatch": return loc("Session request: versions do not match")
        case "Control: unknown error": return loc("Control channel: unknown error")
        case "Control: connect failed": return loc("Control channel: could not connect")
        case "Control: connection refused": return loc("Control channel: the console refused the connection")
        case "Stream: unknown error": return loc("Stream: unknown error")
        case "Stream: remote disconnected": return loc("Stream: the server disconnected")
        case "Stream: remote shut down": return loc("Stream: the server shut down")
        case "PSN registration failed": return loc("PSN registration failed")
        default: return nil
        }
    }
    public static func ended(reason: String, isError: Bool) -> (failure: String?, status: String?) {
        isError ? (reason, nil) : (nil, loc("Session ended: %@", reason))
    }
    public static func isMediaDiagnostic(_ message: String) -> Bool {
        ["audio header:", "audio: "].contains(where: { message.hasPrefix($0) })
    }
    public static func isConnectionDiagnostic(_ message: String) -> Bool {
        ["transport: ", "session: "].contains(where: { message.hasPrefix($0) })
    }
}

public extension RemotePlaySession.Event {
    var isVibration: Bool {
        switch self {
        case .rumble, .haptics: return true
        default: return false
        }
    }
}

public extension DualSenseReport {
    init?(_ event: RemotePlaySession.Event) {
        self.init()
        switch event {
        case .rumble(let left, let right): rumble(left: left, right: right)
        case .triggerEffects(let left, let right): triggers(left: left, right: right)
        case .led(let red, let green, let blue): light(red: red, green: green, blue: blue)
        case .playerIndex(let index): player(index)
        default: return nil
        }
    }
}
