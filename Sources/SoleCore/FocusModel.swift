import Foundation

public struct FocusTarget {
    public let id: String
    public let at: FocusGeometry.Place
    public let activate: () -> Void
    public var adjust: ((Int) -> Void)?
    public init(id: String, at: FocusGeometry.Place, activate: @escaping () -> Void, adjust: ((Int) -> Void)? = nil) {
        self.id = id; self.at = at; self.activate = activate; self.adjust = adjust
    }
}

@MainActor open class FocusModel {
    public var willChange: (() -> Void)?
    private func changing() { willChange?() }
    public init() {}

    public var selected: String? { willSet { changing() } }
    public struct Choice {
        public let title: String
        public let action: () -> Void
        public init(title: String, action: @escaping () -> Void) { self.title = title; self.action = action }
    }
    public var choices: [Choice] = [] { willSet { changing() } }
    public var choiceIndex = 0 { willSet { changing() } }
    public func isFocused(_ id: String) -> Bool { choices.isEmpty && selected == id }

    public private(set) var keyboard: PadKeyboard? { willSet { changing() } }
    private var typed = ""
    private var write: (String) -> Void = { _ in }
    private var closed: (Bool) -> Void = { _ in }
    public func openKeyboard(text: String, write: @escaping (String) -> Void, closed: @escaping (Bool) -> Void = { _ in }) {
        typed = text; self.write = write; self.closed = closed
        keyboard = PadKeyboard()
    }
    public func closeKeyboard(done: Bool = false) {
        guard keyboard != nil else { return }
        keyboard = nil
        let closed = closed
        write = { _ in }; self.closed = { _ in }
        closed(done)
    }
    public func pressKey(_ key: PadKeyboard.Key? = nil) {
        guard let open = keyboard else { return }
        let before = typed
        let done = open.press(key ?? open.selected, on: &typed)
        if typed != before { write(typed) }
        if done { closeKeyboard(done: true) }
    }
    public func pointKey(_ key: PadKeyboard.Key) {
        guard var open = keyboard, open.selected != key else { return }
        open.select(key); keyboard = open
    }
    private func type(_ action: LibraryControllerAction) {
        guard var open = keyboard else { return }
        switch action {
        case .left: open.move(.left); keyboard = open
        case .right: open.move(.right); keyboard = open
        case .up: open.move(.up); keyboard = open
        case .down: open.move(.down); keyboard = open
        case .play: pressKey()
        case .erase: pressKey(.erase)
        case .favorite: pressKey(.space)
        case .settings: closeKeyboard(done: true)
        case .back: closeKeyboard()
        }
    }

    public private(set) var places: [FocusTarget] = []
    public func update(_ places: [FocusTarget]) { self.places = places }

    public func handle(_ action: LibraryControllerAction) -> Bool {
        if keyboard != nil { type(action); return true }
        if !choices.isEmpty {
            switch action {
            case .up, .left: choiceIndex = max(0, choiceIndex - 1)
            case .down, .right: choiceIndex = min(choices.count - 1, choiceIndex + 1)
            case .play: let choice = choices[choiceIndex]; choices = []; choice.action()
            case .back: choices = []
            default: break
            }
            return true
        }
        guard let current = places.first(where: { $0.id == selected }) else {
            selected = FocusGeometry.first(of: places.map(\.id))
            return action != .back && action != .settings
        }
        if action == .play { current.activate(); return true }
        if let adjust = current.adjust, action == .left || action == .right { adjust(action == .right ? 1 : -1); return true }
        let direction: FocusGeometry.Direction
        switch action {
        case .left: direction = .left
        case .right: direction = .right
        case .up: direction = .up
        case .down: direction = .down
        default: return false
        }
        let others = places.filter { $0.id != current.id }.map { (id: $0.id, at: $0.at) }
        if let next = FocusGeometry.next(from: current.at, to: direction, among: others) { selected = next }
        return true
    }
}
