import XCTest
@testable import SoleCore

final class GenerationRoomTests: XCTestCase {
    private let thirty: UInt64 = 33_366_667, sixty: UInt64 = 16_683_333

    func testAGameAtHalfTheRateOfTheDisplayLeavesRoomForAFrameInBetween() {
        var room = GenerationRoom()
        XCTAssertTrue(room.take(interval: thirty, refresh: 60))
        var fast = GenerationRoom()
        XCTAssertTrue(fast.take(interval: sixty, refresh: 120))
    }

    func testAGameAtTheRateOfTheDisplayLeavesNone() {
        var room = GenerationRoom()
        for _ in 0..<120 { XCTAssertFalse(room.take(interval: sixty, refresh: 60)) }
        var fractionalRefresh = GenerationRoom()
        XCTAssertFalse(fractionalRefresh.take(interval: 16_683_350, refresh: 59.98))
    }

    func testFollowsTheGameWhenItsPaceChanges() {
        var room = GenerationRoom()
        for _ in 0..<60 { _ = room.take(interval: sixty, refresh: 60) }
        let opened = (1...15).first { _ in room.take(interval: thirty, refresh: 60) }
        XCTAssertNotNil(opened)
        XCTAssertGreaterThan(opened ?? 0, 3, "Not on the first slow pictures: one repeat is not a change of pace")
        for _ in 0..<60 { XCTAssertTrue(room.take(interval: thirty, refresh: 60)) }
        let closed = (1...15).first { _ in !room.take(interval: sixty, refresh: 60) }
        XCTAssertNotNil(closed)
        XCTAssertGreaterThan(closed ?? 0, 2)
    }

    func testDoesNotSwitchOnAWaveringPace() {
        var wavering = GenerationRoom()
        for index in 0..<240 { XCTAssertFalse(wavering.take(interval: index % 2 == 0 ? sixty : thirty, refresh: 60), "picture \(index)") }
        var steady = GenerationRoom()
        for index in 0..<240 { XCTAssertTrue(steady.take(interval: index % 10 == 9 ? sixty : thirty, refresh: 60), "picture \(index)") }
    }
}
