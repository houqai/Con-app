import Foundation

public enum Upscale {
    public enum Method: String, CaseIterable, Sendable {
        case fsr, nis, anime4k, metalFX
        public func next(in offered: [Method]) -> Method {
            guard let index = offered.firstIndex(of: self) else { return offered.first ?? .fsr }
            return offered[(index + 1) % offered.count]
        }
        public func used(in offered: [Method]) -> Method { offered.contains(self) ? self : offered.first ?? .fsr }
    }
    public static let methodKey = "sole.upscaler"
    public enum Amount: String, CaseIterable, Sendable {
        case double = "2", triple = "3", quadruple = "4"
        public var factor: Double { Double(rawValue) ?? 2 }
        public var next: Amount { self == .double ? .triple : self == .triple ? .quadruple : .double }
        public static func stored(_ value: String?) -> Amount { value.flatMap(Amount.init(rawValue:)) ?? .double }
    }
    public static let amountKey = "sole.upscaleAmount"
    public static let mostPixels = 7680 * 4320

    public static func size(picture: (width: Int, height: Int), amount: Amount) -> (width: Int, height: Int)? {
        guard picture.width > 0, picture.height > 0 else { return nil }
        let scale = min(amount.factor, (Double(mostPixels) / Double(picture.width * picture.height)).squareRoot())
        guard scale >= 1.1 else { return nil }
        func even(_ value: Double) -> Int { max(2, Int((value / 2).rounded()) * 2) }
        return (even(Double(picture.width) * scale), even(Double(picture.height) * scale))
    }
}
