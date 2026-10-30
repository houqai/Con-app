import XCTest
import SoleEngine
@testable import SoleLogic

final class TouchGamepadTests: XCTestCase {
    private func control(_ pad: TouchGamepad, _ id: String) -> TouchGamepad.Control { pad.controls.first { $0.id == id }! }

    func testTheControlsStayOnTheScreenAndDoNotCoverEachOther() {
        for (width, height, left) in [(918.0, 411.0, 0.0), (780.0, 360.0, 0.0), (918.0, 411.0, 40.0), (1280.0, 800.0, 0.0)] {
            let pad = TouchGamepad(width: width, height: height, left: left)
            XCTAssertEqual(pad.controls.count, 15)
            for one in pad.controls {
                XCTAssertGreaterThanOrEqual(one.x - one.radius, left, "\(one.id) at \(width)×\(height)")
                XCTAssertLessThanOrEqual(one.x + one.radius, width, "\(one.id) at \(width)×\(height)")
                XCTAssertGreaterThanOrEqual(one.y - one.radius, 30, "\(one.id) leaves room at the top at \(width)×\(height)")
                XCTAssertLessThanOrEqual(one.y + one.radius, height, "\(one.id) at \(width)×\(height)")
                for other in pad.controls where other.id < one.id {
                    XCTAssertGreaterThan(hypot(one.x - other.x, one.y - other.y), one.radius + other.radius, "\(one.id) and \(other.id) at \(width)×\(height)")
                }
            }
        }
    }

    func testAFingerOnAButtonHoldsItUntilItComesUp() {
        var pad = TouchGamepad(width: 918, height: 411)
        let cross = control(pad, "cross")
        XCTAssertTrue(pad.down(1, x: cross.x + 3, y: cross.y - 2, at: 0))
        XCTAssertEqual(pad.reading(at: 0).buttons, .cross)
        XCTAssertEqual(pad.held, ["cross"])
        pad.up(1, at: 0.5)
        XCTAssertEqual(pad.reading(at: 0.5).buttons, [])
        XCTAssertFalse(pad.down(2, x: 459, y: 150, at: 1), "No control in the center: the touch passes through to the screen")
        XCTAssertEqual(pad.reading(at: 1), PadReading())
    }

    func testAThumbRollsFromOneFaceButtonToTheNext() {
        var pad = TouchGamepad(width: 918, height: 411)
        let cross = control(pad, "cross"), moon = control(pad, "moon")
        pad.down(1, x: cross.x, y: cross.y, at: 0)
        pad.move(1, x: (cross.x + moon.x) / 2, y: (cross.y + moon.y) / 2)
        XCTAssertEqual(pad.reading(at: 0).buttons, .cross, "Between the two the previous button stays pressed")
        pad.move(1, x: moon.x, y: moon.y)
        XCTAssertEqual(pad.reading(at: 0).buttons, .circle)
    }

    func testSticksArePushedAsFarAsTheFingerGoesAndNoFarther() {
        var pad = TouchGamepad(width: 918, height: 411)
        let left = control(pad, "leftStick"), right = control(pad, "rightStick")
        pad.down(1, x: left.x, y: left.y, at: 0)
        pad.move(1, x: left.x + left.radius / 2, y: left.y - left.radius / 2)
        pad.down(2, x: right.x, y: right.y, at: 0)
        pad.move(2, x: right.x - right.radius * 3, y: right.y)
        let reading = pad.reading(at: 0.1)
        XCTAssertEqual(reading.leftX, 0.5, accuracy: 0.001)
        XCTAssertEqual(reading.leftY, 0.5, accuracy: 0.001, "Up on the screen is up for the game")
        XCTAssertEqual(reading.rightX, -1, accuracy: 0.001, "Past the edge of the stick it is fully deflected")
        XCTAssertEqual(reading.rightY, 0, accuracy: 0.001)
        XCTAssertEqual(reading.buttons, [], "A stick that is pushed presses nothing")
        pad.up(1, at: 0.6); pad.up(2, at: 0.6)
        XCTAssertEqual(pad.reading(at: 0.6), PadReading(), "A released stick returns to the center")
    }

    func testATapOnAStickPressesL3OrR3ForAMoment() {
        var pad = TouchGamepad(width: 918, height: 411)
        let right = control(pad, "rightStick")
        pad.down(1, x: right.x, y: right.y, at: 10)
        pad.up(1, at: 10.1)
        XCTAssertEqual(pad.reading(at: 10.15).buttons, .r3)
        XCTAssertEqual(pad.reading(at: 10.1 + TouchGamepad.tapPress + 0.01).buttons, [])
        pad.down(2, x: right.x, y: right.y, at: 20)
        pad.move(2, x: right.x + right.radius, y: right.y)
        pad.up(2, at: 20.1)
        XCTAssertEqual(pad.reading(at: 20.15).buttons, [])
    }

    func testTheCrosspieceHoldsOneDirectionOrADiagonal() {
        var pad = TouchGamepad(width: 918, height: 411)
        let cross = control(pad, "crosspiece")
        pad.down(1, x: cross.x, y: cross.y - cross.radius * 0.8, at: 0)
        XCTAssertEqual(pad.reading(at: 0).buttons, .dpadUp)
        pad.move(1, x: cross.x + cross.radius * 0.6, y: cross.y + cross.radius * 0.6)
        XCTAssertEqual(pad.reading(at: 0).buttons, [.dpadDown, .dpadRight])
        pad.move(1, x: cross.x - cross.radius * 0.8, y: cross.y)
        XCTAssertEqual(pad.reading(at: 0).buttons, .dpadLeft)
        pad.move(1, x: cross.x + 2, y: cross.y)
        XCTAssertEqual(pad.reading(at: 0).buttons, [], "The center presses nothing")
    }

    func testTriggersAndShouldersAndSeveralFingersAtOnce() {
        var pad = TouchGamepad(width: 918, height: 411)
        for (finger, id) in ["l2", "r1", "ps"].enumerated() { pad.down(finger, x: control(pad, id).x, y: control(pad, id).y, at: 0) }
        let reading = pad.reading(at: 0)
        XCTAssertEqual(reading.l2, 1); XCTAssertEqual(reading.r2, 0)
        XCTAssertEqual(reading.buttons, [.r1, .ps])
        pad.cancel()
        XCTAssertEqual(pad.reading(at: 0), PadReading())
    }

    func testAResizeMovesTheControlsAndLetsTheFingersGo() {
        var pad = TouchGamepad(width: 918, height: 411)
        let cross = control(pad, "cross")
        pad.down(1, x: cross.x, y: cross.y, at: 0)
        pad.resize(width: 918, height: 411)
        XCTAssertEqual(pad.held, ["cross"], "The same size changes nothing")
        pad.resize(width: 1280, height: 800)
        XCTAssertEqual(pad.held, [])
    }

    func testTheDevicesGamepadAndTheScreensAreHeldTogether() {
        var device = PadReading(), screen = PadReading()
        device.buttons = .cross; device.leftX = 0.2; device.r2 = 0.4
        screen.buttons = .circle; screen.leftX = -0.9; screen.r2 = 0.1; screen.rightY = 1
        let both = TouchGamepad.combine(device, screen)!
        XCTAssertEqual(both.buttons, [.cross, .circle])
        XCTAssertEqual(both.leftX, -0.9); XCTAssertEqual(both.r2, 0.4); XCTAssertEqual(both.rightY, 1)
        XCTAssertEqual(TouchGamepad.combine(nil, screen), screen)
        XCTAssertNil(TouchGamepad.combine(nil, nil))
    }
}
