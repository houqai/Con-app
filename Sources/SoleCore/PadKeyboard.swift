import Foundation

public struct PadKeyboard: Equatable {
    public enum Key: Hashable, Sendable { case character(Character), space, erase, done }

    public private(set) var row = 1
    public private(set) var column = 0
    public static let limit = 60

    public init() {}

    public var rows: [[Key]] {
        ["1234567890", "qwertyuiop", "asdfghjkl'", "zxcvbnm-:&"].map { $0.map(Key.character) } + [[.space, .erase, .done]]
    }
    public func span(_ key: Key) -> Int {
        switch key {
        case .character: 1
        case .space: 6
        case .erase, .done: 2
        }
    }
    public var selected: Key { rows[row][column] }

    public mutating func move(_ direction: FocusGeometry.Direction) {
        let rows = rows
        switch direction {
        case .left: column = (column - 1 + rows[row].count) % rows[row].count
        case .right: column = (column + 1) % rows[row].count
        case .up, .down:
            let next = row + (direction == .down ? 1 : -1)
            guard rows.indices.contains(next) else { return }
            let middle = middles(of: rows[row])[column]
            let above = middles(of: rows[next])
            column = above.indices.min { abs(above[$0] - middle) < abs(above[$1] - middle) } ?? 0
            row = next
        }
    }
    private func middles(of keys: [Key]) -> [Double] {
        var start = 0
        return keys.map { key in defer { start += span(key) }; return Double(start) + Double(span(key)) / 2 }
    }
    public mutating func select(_ key: Key) {
        for (index, keys) in rows.enumerated() { if let found = keys.firstIndex(of: key) { row = index; column = found; return } }
    }

    public func press(_ key: Key, on text: inout String) -> Bool {
        switch key {
        case .character(let character): if text.count < Self.limit { text.append(character) }
        case .space: if !text.isEmpty, text.last != " ", text.count < Self.limit { text.append(" ") }
        case .erase: if !text.isEmpty { text.removeLast() }
        case .done: return true
        }
        return false
    }
}
