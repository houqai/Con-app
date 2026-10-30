import Foundation
import SoleCore
import SoleEngine

extension Key {
    public static func name(_ key: UInt16) -> String {
        if (Key.a...Key.z).contains(key) { return String(UnicodeScalar(UInt8(65 + key - Key.a))) }
        if (Key.one...Key.zero).contains(key) { return key == Key.zero ? "0" : String(key - Key.one + 1) }
        if (Key.f1...Key.f12).contains(key) { return "F\(key - Key.f1 + 1)" }
        #if os(macOS)
        let enter = "Return", backspace = "Delete", delete = "Fn Delete"
        let leftAlt = loc("Left Option"), rightAlt = loc("Right Option")
        #else
        let enter = "Enter", backspace = "Backspace", delete = "Delete"
        let leftAlt = loc("Left Alt"), rightAlt = loc("Right Alt")
        #endif
        let names: [UInt16: String] = [
            Key.enter: enter, Key.escape: "Esc", Key.backspace: backspace, Key.tab: "Tab", Key.space: loc("Space"),
            Key.minus: "−", Key.equal: "=", Key.leftBracket: "[", Key.rightBracket: "]", Key.backslash: "\\",
            Key.semicolon: ";", Key.quote: "'", Key.grave: "`", Key.comma: ",", Key.period: ".", Key.slash: "/",
            Key.insert: "Insert", Key.home: "Home", Key.pageUp: "Page Up", Key.delete: delete, Key.end: "End", Key.pageDown: "Page Down",
            Key.right: "→", Key.left: "←", Key.down: "↓", Key.up: "↑",
            Key.leftShift: loc("Left Shift"), Key.rightShift: loc("Right Shift"),
            Key.leftControl: loc("Left Control"), Key.rightControl: loc("Right Control"),
            Key.leftAlt: leftAlt, Key.rightAlt: rightAlt,
        ]
        return names[key] ?? loc("key %@", key)
    }
}

extension KeyboardLayout {
    public static let storageKey = "sole.keys"
    public static func stored(in defaults: UserDefaults) -> KeyboardLayout {
        KeyboardLayout(encoded: defaults.dictionary(forKey: storageKey) as? [String: Int] ?? [:])
    }
    public func store(in defaults: UserDefaults) { defaults.set(encoded, forKey: Self.storageKey) }
}

extension PadControl {
    public var title: String {
        switch self {
        case .leftUp: return loc("Forward")
        case .leftLeft: return loc("Left")
        case .leftDown: return loc("Back")
        case .leftRight: return loc("Right")
        case .walk: return loc("Walk")
        case .rightUp: return loc("Camera up")
        case .rightLeft: return loc("Camera left")
        case .rightDown: return loc("Camera down")
        case .rightRight: return loc("Camera right")
        case .cross: return "✕"
        case .circle: return "○"
        case .square: return "□"
        case .triangle: return "△"
        case .l1: return "L1"
        case .r1: return "R1"
        case .l2: return "L2"
        case .r2: return "R2"
        case .l3: return "L3"
        case .r3: return "R3"
        case .dpadUp: return loc("D-pad ↑")
        case .dpadLeft: return loc("D-pad ←")
        case .dpadDown: return loc("D-pad ↓")
        case .dpadRight: return loc("D-pad →")
        case .options: return "Options"
        case .share: return "Create"
        case .touchpad: return loc("Touchpad")
        case .ps: return "PS"
        }
    }

    public static var groups: [(title: String, controls: [PadControl])] { [
        (loc("Movement"), [.leftUp, .leftLeft, .leftDown, .leftRight, .walk]),
        (loc("Camera"), [.rightUp, .rightLeft, .rightDown, .rightRight]),
        (loc("Buttons"), [.cross, .circle, .square, .triangle]),
        (loc("Bumpers and triggers"), [.l1, .r1, .l2, .r2, .l3, .r3]),
        (loc("D-pad"), [.dpadUp, .dpadLeft, .dpadDown, .dpadRight]),
        (loc("System"), [.options, .share, .touchpad, .ps]),
    ] }
}

public struct MouseSettings {
    public static let enabledKey = "sole.mouseCamera", sensitivityKey = "sole.mouseSensitivity", buttonsKey = "sole.mouseButtons"
    public static let sensitivities: ClosedRange<Double> = 1...10
    public static let standardSensitivity = 5.0
    public static var buttonChoices: [(value: String, title: String)] {
        [("triggers", loc("Left is R2, right is L2")), ("bumpers", loc("Left is R1, right is L1"))]
    }

    public let enabled: Bool
    public let sensitivity: Float
    public let bumpers: Bool

    public init(defaults: UserDefaults) {
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        sensitivity = (defaults.object(forKey: Self.sensitivityKey) as? Double).map { Float($0) } ?? Float(Self.standardSensitivity)
        bumpers = defaults.string(forKey: Self.buttonsKey) == "bumpers"
    }
}

extension PadReading {
    public var libraryActions: Set<LibraryControllerAction> {
        var pressed = Set<LibraryControllerAction>()
        let x: Float = buttons.contains(.dpadRight) ? 1 : buttons.contains(.dpadLeft) ? -1 : leftX
        let y: Float = buttons.contains(.dpadUp) ? 1 : buttons.contains(.dpadDown) ? -1 : leftY
        if abs(x) > 0.55 || abs(y) > 0.55 {
            if abs(x) > abs(y) { pressed.insert(x > 0 ? .right : .left) } else { pressed.insert(y > 0 ? .up : .down) }
        }
        if buttons.contains(.cross) { pressed.insert(.play) }
        if buttons.contains(.circle) { pressed.insert(.back) }
        if buttons.contains(.triangle) { pressed.insert(.favorite) }
        if buttons.contains(.square) { pressed.insert(.erase) }
        if buttons.contains(.options) { pressed.insert(.settings) }
        return pressed
    }

    public var held: [String] {
        let named: [(String, ControllerState.Button)] = [
            ("A / ×", .cross), ("B / ○", .circle), ("X / □", .square), ("Y / △", .triangle), ("L1", .l1), ("R1", .r1),
        ]
        var names = named.filter { buttons.contains($0.1) }.map { $0.0 }
        if l2 > 0.1 { names.append("L2") }
        if r2 > 0.1 { names.append("R2") }
        let directions: [(String, ControllerState.Button)] = [("↑", .dpadUp), ("↓", .dpadDown), ("←", .dpadLeft), ("→", .dpadRight)]
        names += directions.filter { buttons.contains($0.1) }.map { $0.0 }
        if abs(leftX) > 0.2 || abs(leftY) > 0.2 { names.append(loc("Left stick")) }
        if abs(rightX) > 0.2 || abs(rightY) > 0.2 { names.append(loc("Right stick")) }
        return names
    }
    public var heldText: String { held.isEmpty ? loc("Press a button or move a stick") : held.joined(separator: " · ") }
}
