public struct ControllerState: Sendable {
    public struct Touch: Sendable, Equatable {
        public var x: UInt16
        public var y: UInt16
        public var id: Int8
        public init(x: UInt16 = 0, y: UInt16 = 0, id: Int8 = -1) { self.x = x; self.y = y; self.id = id }
    }

    public struct Raw: Sendable {
        public var buttons: UInt32 = 0
        public var l2: UInt8 = 0
        public var r2: UInt8 = 0
        public var leftX: Int16 = 0
        public var leftY: Int16 = 0
        public var rightX: Int16 = 0
        public var rightY: Int16 = 0
        public var touches: (Touch, Touch) = (Touch(), Touch())
        public var gyroX: Float = 0, gyroY: Float = 0, gyroZ: Float = 0
        public var accelX: Float = 0, accelY: Float = 1, accelZ: Float = 0
        public var orientX: Float = 0, orientY: Float = 0, orientZ: Float = 0, orientW: Float = 1
        public init() {}
    }

    public var raw = Raw()
    public init() {}
    public static var idle: ControllerState { ControllerState() }

    public struct Button: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let cross = Button(rawValue: 1 << 0)
        public static let circle = Button(rawValue: 1 << 1)
        public static let square = Button(rawValue: 1 << 2)
        public static let triangle = Button(rawValue: 1 << 3)
        public static let dpadLeft = Button(rawValue: 1 << 4)
        public static let dpadRight = Button(rawValue: 1 << 5)
        public static let dpadUp = Button(rawValue: 1 << 6)
        public static let dpadDown = Button(rawValue: 1 << 7)
        public static let l1 = Button(rawValue: 1 << 8)
        public static let r1 = Button(rawValue: 1 << 9)
        public static let l3 = Button(rawValue: 1 << 10)
        public static let r3 = Button(rawValue: 1 << 11)
        public static let options = Button(rawValue: 1 << 12)
        public static let share = Button(rawValue: 1 << 13)
        public static let touchpad = Button(rawValue: 1 << 14)
        public static let ps = Button(rawValue: 1 << 15)
    }

    public mutating func setButtons(_ buttons: Button) { raw.buttons = buttons.rawValue }
    public mutating func setTriggers(l2: Float, r2: Float) {
        func trigger(_ value: Float) -> UInt8 {
            guard value.isFinite, value > 0.01 else { return 0 }
            return UInt8(min(1, value) * 255)
        }
        raw.l2 = trigger(l2)
        raw.r2 = trigger(r2)
    }
    public mutating func setSticks(leftX: Float, leftY: Float, rightX: Float, rightY: Float) {
        func axis(_ value: Float) -> Int16 { Int16(max(-1, min(1, value)) * 32767) }
        raw.leftX = axis(leftX); raw.leftY = axis(-leftY)
        raw.rightX = axis(rightX); raw.rightY = axis(-rightY)
    }
    public mutating func setTouch(slot: Int, id: Int8?, x: Float = 0, y: Float = 0) {
        guard (0..<2).contains(slot) else { return }
        let touch = Touch(x: UInt16(max(0, min(1, (x + 1) / 2)) * 1919), y: UInt16(max(0, min(1, (1 - y) / 2)) * 1079), id: id ?? -1)
        if slot == 0 { raw.touches.0 = touch } else { raw.touches.1 = touch }
    }
}
