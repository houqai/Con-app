import XCTest
@testable import SoleEngine

final class KeyboardPlayTests: XCTestCase {
    func testAHeldKeyCountsOnceAndIsLetGoWithEverythingElse() {
        var play = KeyboardPlay()
        XCTAssertTrue(play.key(Key.w, down: true))
        XCTAssertFalse(play.key(Key.w, down: true), "A held key repeats; only its first press changes anything")
        XCTAssertEqual(play.sample().leftY, 1)
        XCTAssertTrue(play.key(Key.w, down: false))
        XCTAssertFalse(play.key(Key.w, down: false))
        XCTAssertEqual(play.sample(), PadReading())
        _ = play.key(Key.w, down: true); _ = play.key(Key.space, down: true)
        XCTAssertTrue(play.sample().buttons.contains(.cross))
        play.releaseKeys()
        XCTAssertEqual(play.sample(), PadReading(), "The keyboard went to someone else: nothing is held")
    }

    func testAModifierWithASideIsAKeyLikeAnyOther() {
        var layout = KeyboardLayout.standard
        layout.assign(Key.rightShift, to: .r1)
        var play = KeyboardPlay()
        play.begin(layout: layout)
        play.modifier(Key.rightShift, down: true)
        XCTAssertTrue(play.sample().buttons.contains(.r1))
        play.modifier(Key.rightShift, down: false)
        XCTAssertFalse(play.sample().buttons.contains(.r1))
    }

    func testAStreamStartsWithTheLayoutOfTheSettingsAndNothingHeld() {
        var play = KeyboardPlay()
        _ = play.key(Key.w, down: true)
        play.begin(layout: .standard)
        XCTAssertEqual(play.sample(), PadReading())
    }

    func testTheMouseTurnsTheCameraOnlyWhileItIsTaken() {
        var play = KeyboardPlay()
        XCTAssertFalse(play.mouse(.moved(dx: 40, dy: 0)))
        XCTAssertEqual(play.sample().rightX, 0, "The mouse is its own")
        play.captureMouse(sensitivity: 5)
        XCTAssertTrue(play.mouseCaptured)
        XCTAssertFalse(play.mouse(.moved(dx: 40, dy: 0)), "Travel waits for the tick")
        let pushed = play.sample(tick: true)
        XCTAssertGreaterThan(pushed.rightX, 0)
        XCTAssertEqual(play.sample(tick: false).rightX, pushed.rightX, "A reading between ticks repeats the last push")
        XCTAssertTrue(play.releaseMouse())
        XCTAssertFalse(play.releaseMouse(), "It was given back already")
        XCTAssertEqual(play.sample().rightX, 0)
    }

    func testTheMouseButtonsAreTheTriggersOrTheBumpers() {
        var play = KeyboardPlay()
        play.captureMouse(sensitivity: 5)
        XCTAssertTrue(play.mouse(.leftDown), "A press is sent at once")
        XCTAssertEqual(play.sample().r2, 1)
        XCTAssertTrue(play.mouse(.rightDown))
        let bumpers = play.sample(bumpers: true)
        XCTAssertTrue(bumpers.buttons.contains(.r1) && bumpers.buttons.contains(.l1) && bumpers.r2 == 0 && bumpers.l2 == 0)
        XCTAssertTrue(play.mouse(.leftUp))
        XCTAssertEqual(play.sample().r2, 0)
        XCTAssertEqual(play.sample().l2, 1)
        play.releaseMouse()
        play.captureMouse(sensitivity: 5)
        XCTAssertEqual(play.sample().l2, 0, "Taken again, the mouse holds nothing")
    }

    func testCameraKeysKeepTheStickFromTheMouse() {
        var layout = KeyboardLayout.standard
        layout.assign(Key.right, to: .rightRight)
        var play = KeyboardPlay()
        play.begin(layout: layout)
        play.captureMouse(sensitivity: 5)
        _ = play.mouse(.moved(dx: -60, dy: 0))
        _ = play.key(Key.right, down: true)
        XCTAssertEqual(play.sample().rightX, 1)
    }
}
