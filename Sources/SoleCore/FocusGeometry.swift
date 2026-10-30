import Foundation

public enum FocusGeometry {
    public enum Direction: Sendable { case left, right, up, down }
    public typealias Place = (x: Double, y: Double)

    public static func next<ID>(from current: Place, to direction: Direction, among others: [(id: ID, at: Place)]) -> ID? {
        let dx: Double = direction == .left ? -1 : direction == .right ? 1 : 0
        let dy: Double = direction == .up ? -1 : direction == .down ? 1 : 0
        let candidates = others.compactMap { other -> (ID, Double)? in
            let x = other.at.x - current.x, y = other.at.y - current.y
            let forward = x * dx + y * dy
            guard forward > 8 else { return nil }
            let aside = abs(x * dy - y * dx)
            return (other.id, forward + aside * 3)
        }
        return candidates.min(by: { $0.1 < $1.1 })?.0
    }

    public static func first(of ids: [String]) -> String? { ids.first(where: { $0.hasPrefix("game:") }) ?? ids.first }
}
