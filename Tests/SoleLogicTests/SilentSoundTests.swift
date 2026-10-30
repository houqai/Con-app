import XCTest
@testable import SoleLogic

final class SilentSoundTests: XCTestCase {
    func testAGameWhoseSoundNeverComesIsToldOnceAfterThirtySeconds() {
        var watch = SilentSoundWatch()
        XCTAssertEqual(watch.update(received: 0, heard: 0, at: 0), .none, "No sound yet: nothing to tell")
        XCTAssertEqual(watch.update(received: 50, heard: 0, at: 10), .none)
        XCTAssertEqual(watch.update(received: 1500, heard: 0, at: 39.5), .none, "Counted from the first frame")
        XCTAssertEqual(watch.update(received: 1550, heard: 0, at: 40), .silent)
        XCTAssertTrue(watch.silent)
        XCTAssertEqual(watch.update(received: 2000, heard: 0, at: 60), .none, "Once")
        XCTAssertEqual(watch.update(received: 2050, heard: 3, at: 61), .sound, "Sound heard later takes the offer back")
        XCTAssertFalse(watch.silent)
        XCTAssertEqual(watch.update(received: 9000, heard: 3, at: 200), .none)
    }

    func testAGameThatWasHeardIsNeverToldSilentAgain() {
        var watch = SilentSoundWatch()
        XCTAssertEqual(watch.update(received: 100, heard: 20, at: 0), .none)
        XCTAssertEqual(watch.update(received: 5000, heard: 20, at: 100), .none, "A quiet stretch after sound is the game's own")
    }
}
