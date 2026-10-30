import Foundation

public struct KeyboardPlay: Sendable {
    public var layout: KeyboardLayout
    private var pressed = Set<UInt16>()
    public private(set) var mouseCaptured = false
    private var travel: (x: Double, y: Double) = (0, 0)
    private var look = MouseLook()
    private var stick: (x: Float, y: Float) = (0, 0)
    private var leftButton = false
    private var rightButton = false
    public init(layout: KeyboardLayout = .standard) { self.layout = layout }

    public mutating func sample(tick: Bool = true, bumpers: Bool = false) -> PadReading {
        var pad = layout.pad(pressed: pressed)
        guard mouseCaptured else { return pad }
        if tick {
            stick = look.stick(dx: Float(travel.x), dy: Float(travel.y))
            travel = (0, 0)
        }
        if pad.rightX == 0, pad.rightY == 0 { pad.rightX = stick.x; pad.rightY = stick.y }
        if leftButton { if bumpers { pad.buttons.insert(.r1) } else { pad.r2 = 1 } }
        if rightButton { if bumpers { pad.buttons.insert(.l1) } else { pad.l2 = 1 } }
        return pad
    }

    public mutating func begin(layout: KeyboardLayout) { self.layout = layout; pressed = [] }
    public mutating func releaseKeys() { pressed = [] }
    public mutating func key(_ code: UInt16, down: Bool) -> Bool {
        down ? pressed.insert(code).inserted : pressed.remove(code) != nil
    }
    public mutating func modifier(_ code: UInt16, down: Bool) {
        if down { pressed.insert(code) } else { pressed.remove(code) }
    }

    public mutating func captureMouse(sensitivity: Float) {
        look = MouseLook(sensitivity: sensitivity)
        travel = (0, 0); stick = (0, 0); leftButton = false; rightButton = false
        mouseCaptured = true
    }
    @discardableResult public mutating func releaseMouse() -> Bool {
        guard mouseCaptured else { return false }
        mouseCaptured = false; leftButton = false; rightButton = false; travel = (0, 0)
        return true
    }
    public enum MouseEvent: Sendable { case leftDown, leftUp, rightDown, rightUp, moved(dx: Double, dy: Double) }
    public mutating func mouse(_ event: MouseEvent) -> Bool {
        switch event {
        case .leftDown: leftButton = true
        case .leftUp: leftButton = false
        case .rightDown: rightButton = true
        case .rightUp: rightButton = false
        case .moved(let dx, let dy): travel.x += dx; travel.y += dy; return false
        }
        return true
    }
}
