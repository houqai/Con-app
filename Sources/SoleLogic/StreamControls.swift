import Foundation
import SoleCore
import SoleEngine

public extension StreamMenu {
    static func input(from state: ControllerState) -> Input {
        let buttons = ControllerState.Button(rawValue: state.raw.buttons)
        var input: Input = []
        if buttons.contains(.ps) { input.insert(.toggle) }
        if buttons.contains(.cross) { input.insert(.select) }
        if buttons.contains(.circle) || buttons.contains(.options) { input.insert(.back) }
        let tilt: Int16 = 18_000
        if buttons.contains(.dpadUp) || state.raw.leftY < -tilt || state.raw.rightY < -tilt { input.insert(.up) }
        if buttons.contains(.dpadDown) || state.raw.leftY > tilt || state.raw.rightY > tilt { input.insert(.down) }
        return input
    }
}

public struct StreamControls: Sendable {
    public private(set) var menu = StreamMenu()
    private var swallowed: ControllerState.Button = []
    public init() {}

    public mutating func take(_ reading: ControllerState, at time: TimeInterval, generation: Bool, upscaler: Bool = false, upscaleMethod: Bool = false, fullScreen: Bool = true, restart: Bool = false) -> StreamMenu.Outcome {
        let outcome = menu.take(StreamMenu.input(from: reading), at: time, items: StreamMenu.items(generation: generation, upscaler: upscaler, upscaleMethod: upscaleMethod, fullScreen: fullScreen, restart: restart))
        if outcome == .closed { swallowed = ControllerState.Button(rawValue: reading.raw.buttons) }
        return outcome
    }
    public mutating func forGame(_ reading: ControllerState) -> ControllerState {
        let buttons = ControllerState.Button(rawValue: reading.raw.buttons)
        swallowed.formIntersection(buttons)
        if menu.isOpen { return .idle }
        var state = reading
        state.setButtons(buttons.subtracting(swallowed).subtracting(.ps))
        return state
    }
    public mutating func openMenu(generation: Bool, upscaler: Bool = false, upscaleMethod: Bool = false, fullScreen: Bool = true, restart: Bool = false) {
        let items = StreamMenu.items(generation: generation, upscaler: upscaler, upscaleMethod: upscaleMethod, fullScreen: fullScreen, restart: restart)
        if !menu.isOpen || (restart && !menu.items.contains(.restart)) { menu.open(items: items) }
    }
    public mutating func closeMenu(holding buttons: ControllerState.Button = []) { menu.close(); swallowed = buttons }
    public mutating func point(at item: StreamMenu.Item) { menu.select(item) }
    public mutating func reset() { menu.close(); swallowed = [] }
}

public struct TouchSlots: Sendable {
    private var ids: [Int8?] = [nil, nil]
    private var next: Int8 = 0
    public init() {}
    public mutating func id(slot: Int, present: Bool) -> Int8? {
        guard ids.indices.contains(slot) else { return nil }
        if present, ids[slot] == nil { ids[slot] = next; next = Int8((Int(next) + 1) % 128) }
        if !present { ids[slot] = nil }
        return ids[slot]
    }
    public mutating func lift() { ids = [nil, nil] }
}

public struct MotionReference: Sendable {
    public struct Rotation: Equatable, Sendable {
        public var x, y, z, w: Double
        public init(x: Double, y: Double, z: Double, w: Double) { self.x = x; self.y = y; self.z = z; self.w = w }
        public static let none = Rotation(x: 0, y: 0, z: 0, w: 1)
    }
    public private(set) var start = Rotation.none
    public init() {}
    public mutating func reset(to rotation: Rotation) { start = rotation }
    public func relative(_ rotation: Rotation) -> Rotation {
        let length = start.x * start.x + start.y * start.y + start.z * start.z + start.w * start.w
        guard length > 0 else { return rotation }
        let a = Rotation(x: -start.x / length, y: -start.y / length, z: -start.z / length, w: start.w / length), b = rotation
        return Rotation(x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
                        y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
                        z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
                        w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z)
    }
}
