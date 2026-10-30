import Foundation

public enum ColorWheel {
    public static func rgb(hue: Double, lightness: Double = 0.42, chroma: Double = 0.11) -> (red: Double, green: Double, blue: Double) {
        let a = chroma * cos(hue * .pi / 180), b = chroma * sin(hue * .pi / 180)
        let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(lightness - 0.0894841775 * a - 1.291485548 * b, 3)
        func gamma(_ x: Double) -> Double { let x = max(0, min(1, x)); return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055 }
        return (gamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                gamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                gamma(-0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s))
    }
}
