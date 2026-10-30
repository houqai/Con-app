import Testing
import XCTest
@testable import SoleCore

private func hapticsPacket(_ frames: [(Int16, Int16)]) -> Data {
    var data = Data()
    for (left, right) in frames {
        for sample in [left, right] {
            data.append(UInt8(truncatingIfNeeded: sample))
            data.append(UInt8(truncatingIfNeeded: sample >> 8))
        }
    }
    return data
}

final class SoundQueueTests: XCTestCase {
    func testOnlyWholeFramesOfASupportedFormatAreAccepted() {
        XCTAssertTrue(SoundQueue.accepts(samples: 960, channels: 2, rate: 48000))
        XCTAssertTrue(SoundQueue.accepts(samples: 5760 * 8, channels: 8, rate: 192000))
        XCTAssertFalse(SoundQueue.accepts(samples: 0, channels: 2, rate: 48000))
        XCTAssertFalse(SoundQueue.accepts(samples: 961, channels: 2, rate: 48000), "Half a frame")
        XCTAssertFalse(SoundQueue.accepts(samples: 960, channels: 0, rate: 48000))
        XCTAssertFalse(SoundQueue.accepts(samples: 960, channels: 9, rate: 48000))
        XCTAssertFalse(SoundQueue.accepts(samples: 960, channels: 2, rate: 4000))
        XCTAssertFalse(SoundQueue.accepts(samples: 5760 * 2 + 2, channels: 2, rate: 48000), "More than a packet holds")
        XCTAssertFalse(SoundQueue.isAudible([0, 64, -64, 3])); XCTAssertTrue(SoundQueue.isAudible([0, 65])); XCTAssertTrue(SoundQueue.isAudible([-65]))
    }

    func testTheOutputIsSetUpForTheFirstBufferAndWhenTheFormatChanges() {
        var sound = SoundQueue()
        XCTAssertFalse(sound.hasRoom, "Nothing can wait in an output that is not set up")
        XCTAssertTrue(sound.arrived(audible: true, channels: 2, rate: 48000, outputAlive: false, now: 0))
        XCTAssertEqual(sound.stats.restarts, 0, "The first start is no restart")
        sound.started(channels: 2, rate: 48000)
        XCTAssertFalse(sound.arrived(audible: false, channels: 2, rate: 48000, outputAlive: true, now: 0.01))
        XCTAssertTrue(sound.arrived(audible: true, channels: 6, rate: 48000, outputAlive: true, now: 0.02))
        sound.started(channels: 6, rate: 48000)
        XCTAssertTrue(sound.arrived(audible: true, channels: 6, rate: 44100, outputAlive: true, now: 0.03))
        XCTAssertEqual(sound.stats.restarts, 2); XCTAssertEqual(sound.stats.received, 4); XCTAssertEqual(sound.stats.nonSilent, 3)
    }

    func testAStartThatFailsIsTriedAgainWithTheNextBuffer() {
        var sound = SoundQueue()
        XCTAssertTrue(sound.arrived(audible: true, channels: 2, rate: 48000, outputAlive: false, now: 0))
        sound.startFailed()
        XCTAssertEqual(sound.stats.errors, 1); XCTAssertFalse(sound.hasRoom)
        XCTAssertTrue(sound.arrived(audible: true, channels: 2, rate: 48000, outputAlive: false, now: 0.01))
        XCTAssertEqual(sound.stats.restarts, 0, "It never ran")
        sound.started(channels: 2, rate: 48000)
        XCTAssertTrue(sound.hasRoom)
    }

    func testNoMoreThanEightBuffersWaitAndAStalledOutputIsStartedAgain() {
        var sound = SoundQueue()
        _ = sound.arrived(audible: true, channels: 2, rate: 48000, outputAlive: false, now: 0)
        sound.started(channels: 2, rate: 48000)
        var marks: [Int] = []
        for step in 0..<8 { XCTAssertTrue(sound.hasRoom); marks.append(sound.schedule(now: Double(step) * 0.01)) }
        XCTAssertFalse(sound.hasRoom); XCTAssertEqual(sound.stats.pending, 8); XCTAssertEqual(sound.stats.scheduled, 8)
        sound.played(mark: marks[0], now: 0.1)
        XCTAssertTrue(sound.hasRoom); XCTAssertEqual(sound.stats.played, 1)
        XCTAssertFalse(sound.arrived(audible: true, channels: 2, rate: 48000, outputAlive: true, now: 0.3), "A buffer was played a fifth of a second ago")
        XCTAssertTrue(sound.arrived(audible: true, channels: 2, rate: 48000, outputAlive: true, now: 0.36))
        XCTAssertEqual(sound.stats.restarts, 1); XCTAssertEqual(sound.stats.pending, 0)
        sound.started(channels: 2, rate: 48000)
        sound.played(mark: marks[1], now: 0.4)
        XCTAssertEqual(sound.stats.played, 1, "A buffer of the output that was stopped is not counted as played")
        let fresh = sound.schedule(now: 0.41)
        sound.played(mark: fresh, now: 0.42)
        XCTAssertEqual(sound.stats.played, 2); XCTAssertEqual(sound.stats.pending, 0)
    }

    func testAnOutputThatStoppedIsStartedAgainEvenWhenTheQueueIsFull() {
        var sound = SoundQueue()
        _ = sound.arrived(audible: true, channels: 2, rate: 48000, outputAlive: false, now: 0)
        sound.started(channels: 2, rate: 48000)
        for _ in 0..<8 { _ = sound.schedule(now: 0) }
        XCTAssertTrue(sound.arrived(audible: true, channels: 2, rate: 48000, outputAlive: false, now: 0.01), "Checked before queue space")
        XCTAssertEqual(sound.stats.pending, 0)
    }

    func testAnOutputWithNothingWaitingIsNotStalled() {
        var sound = SoundQueue()
        _ = sound.arrived(audible: true, channels: 2, rate: 48000, outputAlive: false, now: 0)
        sound.started(channels: 2, rate: 48000)
        XCTAssertFalse(sound.arrived(audible: true, channels: 2, rate: 48000, outputAlive: true, now: 60), "Silence for a minute is no fault of the output")
        let mark = sound.schedule(now: 60)
        XCTAssertFalse(sound.arrived(audible: true, channels: 2, rate: 48000, outputAlive: true, now: 60.2), "The wait is counted from when the buffer was given")
        sound.played(mark: mark, now: 60.21)
    }

    func testMovingToAnotherDeviceStartsOverAndTheEndOfAStreamForgetsEverything() {
        var sound = SoundQueue()
        XCTAssertFalse(sound.startOver(now: 0), "There is no output to stop yet")
        _ = sound.arrived(audible: true, channels: 2, rate: 48000, outputAlive: false, now: 0)
        sound.started(channels: 2, rate: 48000)
        let mark = sound.schedule(now: 0)
        XCTAssertTrue(sound.startOver(now: 0.1))
        XCTAssertFalse(sound.hasRoom); XCTAssertEqual(sound.stats.pending, 0)
        sound.played(mark: mark, now: 0.2)
        XCTAssertEqual(sound.stats.played, 0)
        XCTAssertTrue(sound.arrived(audible: true, channels: 2, rate: 48000, outputAlive: true, now: 0.3), "Set up again with the next buffer")
        XCTAssertEqual(sound.stats.restarts, 0, "A new start, not a restart")
        sound.started(channels: 2, rate: 48000)
        sound.stop(now: 1)
        XCTAssertEqual(sound.stats.received, 0); XCTAssertFalse(sound.hasRoom)
    }

    func testHapticsAreStretchedSixteenTimesOnAStraightLine() throws {
        let sound = try XCTUnwrap(HapticsSound.actuators(hapticsPacket([(0, 16384), (16384, 0), (-32768, 0)])))
        XCTAssertEqual(sound.left.count, 48); XCTAssertEqual(sound.right.count, 48)
        XCTAssertEqual(sound.left[0], 0); XCTAssertEqual(sound.right[0], 0.5)
        XCTAssertEqual(sound.left[8], 0.25, accuracy: 1e-6, "Halfway to the next frame"); XCTAssertEqual(sound.right[8], 0.25, accuracy: 1e-6)
        XCTAssertEqual(sound.left[16], 0.5); XCTAssertEqual(sound.left[32], -1)
        XCTAssertEqual(sound.left[47], -1, "The last frame has no next one and is held")
        XCTAssertNil(HapticsSound.actuators(Data())); XCTAssertNil(HapticsSound.actuators(Data([1, 2, 3])))
        XCTAssertEqual(HapticsSound.rate, 48000); XCTAssertEqual(HapticsSound.stretch, 16)
    }
}

@Suite struct HapticsMotorsTests {
    private func packet(left: Int16, right: Int16, frames: Int = 64) -> Data {
        hapticsPacket((0..<frames).map { $0 % 2 == 0 ? (left, right) : (-left, -right) })
    }
    @Test func loudHapticsTurnTheMotorsAndFaintOnesDoNot() throws {
        let loud = try #require(HapticsSound.motors(packet(left: 16384, right: 0)))
        #expect(loud.left == 1)
        #expect(loud.right == 0)
        let half = try #require(HapticsSound.motors(packet(left: 4096, right: 4096)))
        #expect(abs(half.left - 0.5) < 0.01)
        #expect(abs(half.right - 0.5) < 0.01)
        let faint = try #require(HapticsSound.motors(packet(left: 200, right: 200)))
        #expect(faint.left == 0 && faint.right == 0)
        #expect(HapticsSound.motors(Data([1, 2, 3])) == nil)
    }
}
