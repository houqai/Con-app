public struct GenerationRoom: Sendable {
    static let opens = 1.75, closes = 1.5
    private var interval = 0.0
    public private(set) var isOpen = false

    public init() {}

    public mutating func take(interval next: UInt64, refresh: Double) -> Bool {
        interval = interval == 0 ? Double(next) : interval + (Double(next) - interval) / 8
        let refreshes = interval * refresh / 1_000_000_000
        if refreshes >= Self.opens { isOpen = true } else if refreshes < Self.closes { isOpen = false }
        return isOpen
    }
}
