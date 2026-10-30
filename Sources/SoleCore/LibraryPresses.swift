import Foundation

public enum LibraryControllerAction: Hashable, Sendable { case left, right, up, down, play, back, favorite, settings, erase }

public struct LibraryPresses: Sendable {
    private var held = Set<LibraryControllerAction>()
    private var nextRepeat: [LibraryControllerAction: TimeInterval] = [:]
    private var yielded = false
    private static let firstRepeatDelay: TimeInterval = 0.38, repeatInterval: TimeInterval = 0.14

    public init() {}

    public mutating func reset() { held = []; nextRepeat = [:] }

    public mutating func take(_ pressed: Set<LibraryControllerAction>, yielding: Bool, at now: TimeInterval) -> [LibraryControllerAction] {
        if yielding { yielded = true }
        if yielded {
            held = pressed; nextRepeat = [:]
            yielded = yielding
            return []
        }
        var actions: [LibraryControllerAction] = []
        for button in pressed {
            let direction = [.left, .right, .up, .down].contains(button)
            if !held.contains(button) {
                actions.append(button); nextRepeat[button] = now + Self.firstRepeatDelay
            } else if direction, now >= (nextRepeat[button] ?? .infinity) {
                actions.append(button); nextRepeat[button] = now + Self.repeatInterval
            }
        }
        nextRepeat = nextRepeat.filter { pressed.contains($0.key) }; held = pressed
        return actions
    }
}
