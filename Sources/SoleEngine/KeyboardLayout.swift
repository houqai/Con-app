import Foundation

public enum PadControl: String, CaseIterable, Sendable {
    case leftUp, leftLeft, leftDown, leftRight, walk
    case rightUp, rightLeft, rightDown, rightRight
    case cross, circle, square, triangle
    case l1, r1, l2, r2, l3, r3
    case dpadUp, dpadLeft, dpadDown, dpadRight
    case options, share, touchpad, ps
}

public struct KeyboardLayout: Equatable, Sendable {
    public private(set) var keys: [PadControl: UInt16]

    public static let standard = KeyboardLayout(keys: [
        .leftUp: Key.w, .leftLeft: Key.a, .leftDown: Key.s, .leftRight: Key.d, .walk: Key.leftAlt,
        .rightUp: Key.up, .rightLeft: Key.left, .rightDown: Key.down, .rightRight: Key.right,
        .cross: Key.space, .circle: Key.leftShift, .square: Key.e, .triangle: Key.q,
        .l1: Key.v, .r1: Key.f, .l2: Key.c, .r2: Key.r, .l3: Key.leftControl, .r3: Key.rightShift,
        .dpadUp: Key.i, .dpadLeft: Key.j, .dpadDown: Key.k, .dpadRight: Key.l,
        .options: Key.escape, .share: Key.y, .touchpad: Key.t, .ps: Key.p,
    ])

    private init(keys: [PadControl: UInt16]) { self.keys = keys }

    public init(encoded: [String: Int]) {
        var layout = KeyboardLayout.standard
        for (name, key) in encoded {
            guard let control = PadControl(rawValue: name), (0...0xFFFF).contains(key) else { continue }
            layout.keys[control] = UInt16(key)
        }
        self = layout
    }
    public var encoded: [String: Int] { Dictionary(uniqueKeysWithValues: keys.map { ($0.key.rawValue, Int($0.value)) }) }

    public mutating func assign(_ key: UInt16, to control: PadControl) {
        let previous = keys[control]
        if let other = keys.first(where: { $0.value == key && $0.key != control })?.key { keys[other] = previous }
        keys[control] = key
    }

    public func pad(pressed: Set<UInt16>) -> PadReading {
        func down(_ control: PadControl) -> Bool { keys[control].map(pressed.contains) ?? false }
        func axis(_ positive: PadControl, _ negative: PadControl) -> Float { (down(positive) ? 1 : 0) - (down(negative) ? 1 : 0) }
        func stick(_ x: Float, _ y: Float, scale: Float = 1) -> (Float, Float) {
            let diagonal: Float = x != 0 && y != 0 ? 0.70710678 : 1
            return (x * diagonal * scale, y * diagonal * scale)
        }
        var pad = PadReading()
        (pad.leftX, pad.leftY) = stick(axis(.leftRight, .leftLeft), axis(.leftUp, .leftDown), scale: down(.walk) ? 0.5 : 1)
        (pad.rightX, pad.rightY) = stick(axis(.rightRight, .rightLeft), axis(.rightUp, .rightDown))
        pad.l2 = down(.l2) ? 1 : 0
        pad.r2 = down(.r2) ? 1 : 0
        let buttons: [(PadControl, ControllerState.Button)] = [
            (.cross, .cross), (.circle, .circle), (.square, .square), (.triangle, .triangle),
            (.l1, .l1), (.r1, .r1), (.l3, .l3), (.r3, .r3),
            (.dpadUp, .dpadUp), (.dpadLeft, .dpadLeft), (.dpadDown, .dpadDown), (.dpadRight, .dpadRight),
            (.options, .options), (.share, .share), (.touchpad, .touchpad), (.ps, .ps),
        ]
        for (control, button) in buttons where down(control) { pad.buttons.insert(button) }
        return pad
    }
}

public struct PadReading: Equatable, Sendable {
    public var buttons: ControllerState.Button = []
    public var l2: Float = 0
    public var r2: Float = 0
    public var leftX: Float = 0
    public var leftY: Float = 0
    public var rightX: Float = 0
    public var rightY: Float = 0
    public init() {}
}

extension ControllerState {
    public mutating func merge(_ keyboard: PadReading, pad: PadReading) {
        merge(keyboard, buttons: pad.buttons, l2: pad.l2, r2: pad.r2, leftX: pad.leftX, leftY: pad.leftY, rightX: pad.rightX, rightY: pad.rightY)
    }
    public mutating func merge(_ keyboard: PadReading, buttons: Button, l2: Float, r2: Float, leftX: Float, leftY: Float, rightX: Float, rightY: Float) {
        setButtons(buttons.union(keyboard.buttons))
        setTriggers(l2: max(l2, keyboard.l2), r2: max(r2, keyboard.r2))
        let left = keyboard.leftX != 0 || keyboard.leftY != 0, right = keyboard.rightX != 0 || keyboard.rightY != 0
        setSticks(leftX: left ? keyboard.leftX : leftX, leftY: left ? keyboard.leftY : leftY,
                  rightX: right ? keyboard.rightX : rightX, rightY: right ? keyboard.rightY : rightY)
    }
}
