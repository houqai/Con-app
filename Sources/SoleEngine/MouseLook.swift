import Foundation

public struct MouseLook: Sendable {
    public var sensitivity: Float { didSet { sensitivity = min(10, max(1, sensitivity)) } }
    static let deadZone: Float = 0.2
    static let weakest: Float = 0.06
    static let reserve: Float = 44
    private var owedX: Float = 0
    private var owedY: Float = 0

    public init(sensitivity: Float = 5) { self.sensitivity = min(10, max(1, sensitivity)) }

    public mutating func stick(dx: Float, dy: Float) -> (x: Float, y: Float) {
        owedX += dx
        owedY -= dy
        let full = 33.3 / sensitivity
        var owed = (owedX * owedX + owedY * owedY).squareRoot()
        if owed > full * Self.reserve {
            owedX *= full * Self.reserve / owed; owedY *= full * Self.reserve / owed
            owed = full * Self.reserve
        }
        let push = min(1, owed / (2 * full))
        guard push >= Self.weakest else { return (0, 0) }
        let paid = push * full
        let x = owedX / owed, y = owedY / owed
        owedX -= x * paid; owedY -= y * paid
        let pushed = Self.deadZone + (1 - Self.deadZone) * push
        return (x * pushed, y * pushed)
    }
}
