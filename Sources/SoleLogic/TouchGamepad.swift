import Foundation
import SoleEngine

public struct TouchGamepad: Sendable {
    public enum Kind: String, Sendable { case button, trigger, stick, dpad = "crosspiece" }

    public struct Control: Equatable, Sendable {
        public let id: String
        public let kind: Kind
        public let label: String
        public let x: Double, y: Double
        public let radius: Double
        public let button: ControllerState.Button
    }

    public static func layout(width: Double, height: Double, left: Double = 0, right: Double = 0) -> [Control] {
        let scale = min(1.15, max(0.7, height / 400)), margin = 24.0
        let stick = 58 * scale, cross = 56 * scale, face = 24 * scale, shoulder = 26 * scale, small = 17 * scale
        let reach = face * 1.75, cluster = max(cross, reach + face)
        let leftEdge = left + margin, rightEdge = width - right - margin
        let stickY = height - margin - stick - 6, upperY = min(height * 0.47, stickY - stick - cluster - 12)
        let shoulderY = max(64, upperY - cluster - shoulder - 10)
        let leftStick = leftEdge + stick + 44 * scale, rightStick = rightEdge - stick - 44 * scale
        let faceX = rightEdge - reach - face, crossX = leftEdge + cross + 4
        let middle = (left + width - right) / 2, bottom = height - 14 - small
        return [
            Control(id: "l2", kind: .trigger, label: "L2", x: leftEdge + shoulder, y: shoulderY, radius: shoulder, button: []),
            Control(id: "l1", kind: .button, label: "L1", x: leftEdge + 3 * shoulder + 12, y: shoulderY, radius: shoulder, button: .l1),
            Control(id: "r1", kind: .button, label: "R1", x: rightEdge - 3 * shoulder - 12, y: shoulderY, radius: shoulder, button: .r1),
            Control(id: "r2", kind: .trigger, label: "R2", x: rightEdge - shoulder, y: shoulderY, radius: shoulder, button: []),
            Control(id: "crosspiece", kind: .dpad, label: "", x: crossX, y: upperY, radius: cross, button: []),
            Control(id: "leftStick", kind: .stick, label: "L3", x: leftStick, y: stickY, radius: stick, button: .l3),
            Control(id: "pyramid", kind: .button, label: "△", x: faceX, y: upperY - reach, radius: face, button: .triangle),
            Control(id: "box", kind: .button, label: "□", x: faceX - reach, y: upperY, radius: face, button: .square),
            Control(id: "moon", kind: .button, label: "○", x: faceX + reach, y: upperY, radius: face, button: .circle),
            Control(id: "cross", kind: .button, label: "✕", x: faceX, y: upperY + reach, radius: face, button: .cross),
            Control(id: "rightStick", kind: .stick, label: "R3", x: rightStick, y: stickY, radius: stick, button: .r3),
            Control(id: "share", kind: .button, label: "Create", x: middle - 4 * small, y: bottom, radius: small, button: .share),
            Control(id: "ps", kind: .button, label: "PS", x: middle, y: bottom, radius: small, button: .ps),
            Control(id: "options", kind: .button, label: "Options", x: middle + 4 * small, y: bottom, radius: small, button: .options),
            Control(id: "touchpad", kind: .button, label: "", x: middle, y: bottom - 2 * small - 18, radius: small * 1.4, button: .touchpad),
        ]
    }

    public private(set) var controls: [Control]
    private struct Finger: Sendable { var control: String; var startX, startY, x, y: Double; var since: TimeInterval }
    private var fingers: [Int: Finger] = [:]
    private var taps: [(button: ControllerState.Button, until: TimeInterval)] = []
    public static let tapPress: TimeInterval = 0.12

    public init(width: Double, height: Double, left: Double = 0, right: Double = 0) {
        controls = Self.layout(width: width, height: height, left: left, right: right)
    }

    public mutating func resize(width: Double, height: Double, left: Double = 0, right: Double = 0) {
        let moved = Self.layout(width: width, height: height, left: left, right: right)
        guard moved != controls else { return }
        controls = moved; fingers = [:]
    }

    private func control(_ id: String) -> Control? { controls.first { $0.id == id } }

    private func hit(_ x: Double, _ y: Double) -> Control? {
        var best: Control?, nearest = Double.infinity
        for control in controls {
            let room = control.radius * (control.kind == .stick ? 1.6 : 1.3)
            let distance: Double = hypot(x - control.x, y - control.y)
            if distance <= room, distance / control.radius < nearest { best = control; nearest = distance / control.radius }
        }
        return best
    }

    @discardableResult
    public mutating func down(_ finger: Int, x: Double, y: Double, at time: TimeInterval) -> Bool {
        guard let control = hit(x, y) else { fingers[finger] = nil; return false }
        fingers[finger] = Finger(control: control.id, startX: x, startY: y, x: x, y: y, since: time)
        return true
    }

    public mutating func move(_ finger: Int, x: Double, y: Double) {
        guard var held = fingers[finger] else { return }
        held.x = x; held.y = y
        if let now = control(held.control), now.kind == .button, Self.faces.contains(now.id),
           let other = controls.filter({ Self.faces.contains($0.id) }).min(by: { hypot(x - $0.x, y - $0.y) < hypot(x - $1.x, y - $1.y) }),
           hypot(x - other.x, y - other.y) <= other.radius * 1.1 {
            held.control = other.id
        }
        fingers[finger] = held
    }
    private static let faces: Set<String> = ["cross", "moon", "box", "pyramid"]

    public mutating func up(_ finger: Int, at time: TimeInterval) {
        guard let held = fingers.removeValue(forKey: finger) else { return }
        if let stick = control(held.control), stick.kind == .stick, time - held.since < 0.25,
           hypot(held.x - held.startX, held.y - held.startY) < stick.radius * 0.25 {
            taps.append((stick.button, time + Self.tapPress))
        }
    }

    public mutating func cancel() { fingers = [:]; taps = [] }

    public func stick(_ id: String) -> (x: Double, y: Double) {
        guard let control = control(id), let held = fingers.values.first(where: { $0.control == id }) else { return (0, 0) }
        var x = (held.x - control.x) / control.radius, y = -(held.y - control.y) / control.radius
        let length = hypot(x, y)
        if length > 1 { x /= length; y /= length }
        return (x, y)
    }

    public var dpad: ControllerState.Button {
        guard let control = control("crosspiece"), let held = fingers.values.first(where: { $0.control == "crosspiece" }) else { return [] }
        let x = held.x - control.x, y = held.y - control.y
        guard hypot(x, y) > control.radius * 0.25 else { return [] }
        let sector = Int(((atan2(-y, x) * 180 / .pi + 360 + 22.5).truncatingRemainder(dividingBy: 360)) / 45)
        let directions: [ControllerState.Button] = [.dpadRight, [.dpadRight, .dpadUp], .dpadUp, [.dpadUp, .dpadLeft], .dpadLeft, [.dpadLeft, .dpadDown], .dpadDown, [.dpadDown, .dpadRight]]
        return directions[sector]
    }

    public var held: Set<String> { Set(fingers.values.map(\.control)) }

    public func reading(at time: TimeInterval) -> PadReading {
        var reading = PadReading()
        for id in held { if let control = control(id), control.kind == .button { reading.buttons.insert(control.button) } }
        reading.buttons.formUnion(dpad)
        for tap in taps where time < tap.until { reading.buttons.insert(tap.button) }
        if held.contains("l2") { reading.l2 = 1 }
        if held.contains("r2") { reading.r2 = 1 }
        let left = stick("leftStick"), right = stick("rightStick")
        reading.leftX = Float(left.x); reading.leftY = Float(left.y)
        reading.rightX = Float(right.x); reading.rightY = Float(right.y)
        return reading
    }

    public mutating func forget(before time: TimeInterval) { taps.removeAll { $0.until <= time } }

    public static func combine(_ one: PadReading?, _ other: PadReading?) -> PadReading? {
        guard let one else { return other }
        guard let other else { return one }
        var both = one
        both.buttons.formUnion(other.buttons)
        both.l2 = max(one.l2, other.l2); both.r2 = max(one.r2, other.r2)
        func push(_ x: Float, _ y: Float) -> Float { x * x + y * y }
        if push(other.leftX, other.leftY) > push(one.leftX, one.leftY) { both.leftX = other.leftX; both.leftY = other.leftY }
        if push(other.rightX, other.rightY) > push(one.rightX, one.rightY) { both.rightX = other.rightX; both.rightY = other.rightY }
        return both
    }
}
