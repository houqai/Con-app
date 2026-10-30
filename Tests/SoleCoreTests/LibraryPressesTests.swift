import XCTest
@testable import SoleCore

final class LibraryPressesTests: XCTestCase {
    func testAControlActsOnceWhenItGoesDownAndADirectionGoesOnWhileHeld() {
        var presses = LibraryPresses()
        XCTAssertEqual(presses.take([.play], yielding: false, at: 0), [.play])
        XCTAssertEqual(presses.take([.play], yielding: false, at: 0.05), [])
        XCTAssertEqual(presses.take([.play], yielding: false, at: 2), [], "A button is not repeated")
        XCTAssertEqual(presses.take([], yielding: false, at: 2.05), [])
        XCTAssertEqual(presses.take([.play], yielding: false, at: 2.1), [.play])
        XCTAssertEqual(presses.take([.down], yielding: false, at: 3), [.down])
        XCTAssertEqual(presses.take([.down], yielding: false, at: 3.3), [])
        XCTAssertEqual(presses.take([.down], yielding: false, at: 3.4), [.down], "After the pause")
        XCTAssertEqual(presses.take([.down], yielding: false, at: 3.5), [])
        XCTAssertEqual(presses.take([.down], yielding: false, at: 3.55), [.down], "Then faster")
    }

    func testAButtonThatClosedTheStreamDoesNotActInTheLibrary() {
        var presses = LibraryPresses()
        XCTAssertEqual(presses.take([], yielding: true, at: 0), [])
        XCTAssertEqual(presses.take([.play], yielding: false, at: 0.05), [], "Pressed for the stream")
        for step in 2...30 { XCTAssertEqual(presses.take([.play], yielding: false, at: Double(step) * 0.05), []) }
        XCTAssertEqual(presses.take([], yielding: false, at: 2), [])
        XCTAssertEqual(presses.take([.play], yielding: false, at: 2.05), [.play], "Released and pressed again: now it goes to the library")
    }

    func testNothingActsWhileAStreamHasTheGamepad() {
        var presses = LibraryPresses()
        for step in 0..<40 { XCTAssertEqual(presses.take(step % 4 < 2 ? [.play, .down] : [], yielding: true, at: Double(step) * 0.05), []) }
        XCTAssertEqual(presses.take([.down], yielding: true, at: 2), [])
        for step in 1...30 { XCTAssertEqual(presses.take([.down], yielding: false, at: 2 + Double(step) * 0.05), []) }
        XCTAssertEqual(presses.take([], yielding: false, at: 4), [])
        XCTAssertEqual(presses.take([.down], yielding: false, at: 4.05), [.down])
        XCTAssertEqual(presses.take([], yielding: true, at: 5), [])
        XCTAssertEqual(presses.take([.back], yielding: true, at: 5.05), [])
    }

    func testLosingTheGamepadDoesNotGiveTheStreamsButtonToTheLibrary() {
        var presses = LibraryPresses()
        _ = presses.take([], yielding: true, at: 0)
        presses.reset()
        XCTAssertEqual(presses.take([.play], yielding: false, at: 1), [], "The first reading after a stream is still ignored")
    }
}
