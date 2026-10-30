import Foundation
import SoleCore
import SoleEngine
import SoleLogic

final class AndroidTouch: @unchecked Sendable {
    private enum Action: Int32 { case layout, down, move, up, cancel }
    static let shared = AndroidTouch()
    private let lock = NSLock()
    private var pad = TouchGamepad(width: 918, height: 411)

    func touch(action code: Int32, finger: Int32, x: Double, y: Double, width: Double, height: Double, left: Double, right: Double) -> [String: Any] {
        let action = Action(rawValue: code)
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        pad.resize(width: width, height: height, left: left, right: right)
        var hit = false
        switch action {
        case .down: hit = pad.down(Int(finger), x: x, y: y, at: now)
        case .move: pad.move(Int(finger), x: x, y: y)
        case .up: pad.up(Int(finger), at: now)
        case .cancel: pad.cancel()
        case .layout, nil: break
        }
        pad.forget(before: now)
        let reading = pad.reading(at: now), held = pad.held, left = pad.stick("leftStick"), right = pad.stick("rightStick")
        let dpad = pad.dpad
        var answer: [String: Any] = ["hit": hit, "held": Array(held), "left": [left.x, left.y], "right": [right.x, right.y],
                                     "up": dpad.contains(.dpadUp), "down": dpad.contains(.dpadDown),
                                     "leftward": dpad.contains(.dpadLeft), "rightward": dpad.contains(.dpadRight)]
        if action == .layout {
            answer["controls"] = pad.controls.map { ["id": $0.id, "kind": $0.kind.rawValue, "label": $0.label, "x": $0.x, "y": $0.y, "radius": $0.radius] }
        }
        lock.unlock()
        let empty = reading == PadReading() && action == .cancel
        Task { @MainActor in AndroidApp.shared?.takeTouch(empty ? nil : reading) }
        if action == .up {
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64((TouchGamepad.tapPress + 0.01) * 1_000_000_000))
                let later = self.reading()
                await MainActor.run { AndroidApp.shared?.takeTouch(later) }
            }
        }
        return answer
    }

    private func reading() -> PadReading {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        pad.forget(before: now)
        return pad.reading(at: now)
    }
}

@_cdecl("con_touch")
public func conTouch(_ action: Int32, _ finger: Int32, _ x: Float, _ y: Float, _ width: Float, _ height: Float, _ left: Float, _ right: Float) -> UnsafeMutablePointer<CChar>? {
    let answer = AndroidTouch.shared.touch(action: action, finger: finger, x: Double(x), y: Double(y), width: Double(width), height: Double(height), left: Double(left), right: Double(right))
    let data = (try? JSONSerialization.data(withJSONObject: answer, options: [])) ?? Data("{}".utf8)
    return strdup(String(decoding: data, as: UTF8.self))
}
