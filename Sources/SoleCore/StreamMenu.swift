import Foundation

public struct StreamMenu: Equatable, Sendable {
    public enum Item: Hashable, Sendable { case restart, resume, stats, generation, upscaler, upscaleAmount, upscaleMethod, fullScreen, leave }
    public struct Input: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let up = Input(rawValue: 1), down = Input(rawValue: 2), select = Input(rawValue: 4), back = Input(rawValue: 8), toggle = Input(rawValue: 16)
    }
    public enum Outcome: Equatable, Sendable { case none, opened, closed, chosen(Item) }

    public private(set) var isOpen = false
    public private(set) var selection = 0
    public private(set) var items: [Item] = []
    private var held: Input = []
    private var repeatAt = TimeInterval.infinity

    public init() {}
    public static func == (a: StreamMenu, b: StreamMenu) -> Bool { a.isOpen == b.isOpen && a.selection == b.selection && a.items == b.items }

    public static func items(generation: Bool, upscaler: Bool = false, upscaleMethod: Bool = false, fullScreen: Bool = true, restart: Bool = false) -> [Item] {
        (restart ? [.restart] : []) + [.resume, .stats] + (generation ? [.generation] : []) + (upscaler ? [.upscaler, .upscaleAmount] + (upscaleMethod ? [.upscaleMethod] : []) : [])
            + (fullScreen ? [.fullScreen] : []) + [.leave]
    }

    public mutating func open(items: [Item]) { self.items = items; selection = 0; isOpen = true; repeatAt = .infinity }
    public mutating func close() { isOpen = false; repeatAt = .infinity }
    public mutating func select(_ item: Item) { if let index = items.firstIndex(of: item) { selection = index } }

    public mutating func take(_ input: Input, at time: TimeInterval, items offered: @autoclosure () -> [Item]) -> Outcome {
        defer { held = input }
        let pressed = input.subtracting(held)
        if pressed.contains(.toggle) {
            if isOpen { close(); return .closed }
            open(items: offered()); return .opened
        }
        guard isOpen else { return .none }
        if pressed.contains(.back) { close(); return .closed }
        if pressed.contains(.select), items.indices.contains(selection) { return .chosen(items[selection]) }
        let direction = input.intersection([.up, .down])
        guard direction == .up || direction == .down else { repeatAt = .infinity; return .none }
        if pressed.contains(direction) { repeatAt = time + 0.38 } else if time >= repeatAt { repeatAt = time + 0.14 } else { return .none }
        selection = min(max(selection + (direction == .down ? 1 : -1), 0), max(items.count - 1, 0))
        return .none
    }
}
