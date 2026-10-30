import XCTest
@testable import SoleCore

final class ColorWheelTests: XCTestCase {
    func testAColorWithZeroChromaIsGray() {
        let gray = ColorWheel.rgb(hue: 123, lightness: 0.5, chroma: 0)
        XCTAssertEqual(gray.red, gray.green, accuracy: 0.0001); XCTAssertEqual(gray.green, gray.blue, accuracy: 0.0001)
        XCTAssertGreaterThan(ColorWheel.rgb(hue: 0, lightness: 0.8, chroma: 0).red, gray.red, "Higher lightness gives a brighter gray")
    }

    func testTheHueSelectsTheColor() {
        let red = ColorWheel.rgb(hue: 30), green = ColorWheel.rgb(hue: 140), blue = ColorWheel.rgb(hue: 265)
        XCTAssertTrue(red.red > red.green && red.red > red.blue)
        XCTAssertTrue(green.green > green.red && green.green > green.blue)
        XCTAssertTrue(blue.blue > blue.red && blue.blue > blue.green)
    }

    func testEveryColorFitsTheScreenAndTheHueWrapsAround() {
        for hue in stride(from: 0.0, to: 360, by: 7) {
            for (lightness, chroma) in [(0.42, 0.11), (0.45, 0.16), (0.32, 0.12), (0.4, 0.12)] {
                let color = ColorWheel.rgb(hue: hue, lightness: lightness, chroma: chroma)
                for part in [color.red, color.green, color.blue] { XCTAssertTrue((0...1).contains(part), "hue \(hue)") }
            }
            let once = ColorWheel.rgb(hue: hue), again = ColorWheel.rgb(hue: hue + 360)
            XCTAssertEqual(once.red, again.red, accuracy: 0.0001); XCTAssertEqual(once.blue, again.blue, accuracy: 0.0001)
        }
    }

    func testTheNumbersAreTheOnesTheCoversWereDrawnWith() {
        let expected: [(hue: Double, lightness: Double, chroma: Double, rgb: [Double])] = [
            (100, 0.42, 0.11, [0.3592, 0.3016, 0.0000]), (250, 0.45, 0.16, [0.0000, 0.3336, 0.6620]), (20, 0.32, 0.12, [0.3843, 0.0322, 0.0910]),
        ]
        for row in expected {
            let color = ColorWheel.rgb(hue: row.hue, lightness: row.lightness, chroma: row.chroma)
            XCTAssertEqual(color.red, row.rgb[0], accuracy: 0.0001, "hue \(row.hue)")
            XCTAssertEqual(color.green, row.rgb[1], accuracy: 0.0001, "hue \(row.hue)")
            XCTAssertEqual(color.blue, row.rgb[2], accuracy: 0.0001, "hue \(row.hue)")
        }
    }
}
