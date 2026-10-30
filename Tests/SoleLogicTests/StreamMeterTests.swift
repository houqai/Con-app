import XCTest
import SoleCore
import SoleEngine
#if canImport(simd)
import simd
#endif
@testable import SoleLogic

final class StreamMeterTests: XCTestCase {
    func testTheDelayOfAStreamIsItsPingAndTheWayToTheDisplay() {
        var stats = StreamStats()
        XCTAssertNil(stats.delayMs, "Without a ping there is nothing to call a delay")
        stats.screenDelayMs = 34.9
        XCTAssertNil(stats.delayMs)
        stats.measuredPingMs = 99
        XCTAssertEqual(stats.delayMs, 134, "The ping measured before the stream, until it is measured in it")
        stats.livePingMs = 103
        XCTAssertEqual(stats.delayMs, 138)
        stats.screenDelayMs = 65.6
        XCTAssertEqual(stats.delayMs, 169)
    }

    func testAPictureHandedOverAtItsTimeCountsItsWait() {
        var video = VideoStats()
        video.decodeMs = 4; video.presentationMs = 21
        XCTAssertEqual(video.screenDelayMs(displayRate: 60), 4 + 21 + 1000.0 / 120 + 2, accuracy: 0.001, "Timed ahead")
        video.deliveryMs = 5; video.shownAtHandOver = true
        XCTAssertEqual(video.screenDelayMs(displayRate: 60), 4 + 5 + 1000.0 / 60 * 1.4 + 1000.0 / 120 + 2, accuracy: 0.001, "Handed over at its time")
    }

    private func reading(received: Int = 0, shown: Int = 0, new: Int = 0, generated: Int = 0, bytes: Int = 0, lost: Int = 0, failures: Int = 0) -> StreamMeter.Reading {
        var reading = StreamMeter.Reading()
        reading.video.receivedFrames = received; reading.video.shownFrames = shown; reading.video.newFrames = new
        reading.video.generatedFrames = generated; reading.video.bytes = bytes; reading.video.missingFrames = lost; reading.video.decodeFailures = failures
        return reading
    }

    func testRatesAreWhatChangedBetweenTwoReadings() {
        var meter = StreamMeter()
        let first = meter.sample(reading(received: 100, shown: 100, new: 50, generated: 0, bytes: 1_000_000), at: 10)
        XCTAssertEqual(first.framesPerSecond, 0, "One reading says nothing about a rate")
        XCTAssertEqual(first.seconds, 0)
        let second = meter.sample(reading(received: 130, shown: 130, new: 115, generated: 15, bytes: 2_250_000), at: 10.5)
        XCTAssertEqual(second.framesPerSecond, 60); XCTAssertEqual(second.newPerSecond, 130)
        XCTAssertEqual(second.generatedPerSecond, 30)
        XCTAssertEqual(second.submittedPerSecond, 90, "Shown and generated pictures together")
        XCTAssertEqual(second.bitrateMbps, 20)
        let hasty = meter.sample(reading(received: 131, shown: 131, new: 116, generated: 15, bytes: 2_260_000), at: 10.55)
        XCTAssertEqual(hasty.framesPerSecond, 60, "Two readings too close keep the rates of the reading before")
        XCTAssertEqual(meter.sample(reading(received: 191, shown: 191), at: 13.7).seconds, 3)
    }

    func testHiddenPicturesAreNeitherLostNorHeld() {
        var meter = StreamMeter()
        var reading = self.reading(received: 300, shown: 282, lost: 2, failures: 0)
        reading.video.hiddenFrames = 16
        var stats = meter.sample(reading, at: 0)
        XCTAssertEqual(stats.hiddenFrames, 16, "The media's own count without the engine's")
        XCTAssertEqual(stats.hiddenRuns, 0)
        reading.hidden = (frames: 18, runs: 2)
        stats = meter.sample(reading, at: 1)
        XCTAssertEqual(stats.hiddenFrames, 18); XCTAssertEqual(stats.hiddenRuns, 2)
        XCTAssertEqual(stats.lostFrames, 2); XCTAssertEqual(stats.decodeFailures, 0)
        XCTAssertEqual(stats.health["hiddenFrames"] as? Int, 18)
        XCTAssertEqual(stats.health["hiddenRuns"] as? Int, 2)
        XCTAssertEqual(stats.health["decodeFailures"] as? Int, 0)
    }

    func testThePingOfAStreamIsTheMiddleOfItsLastFiveMeasurements() {
        var meter = StreamMeter(server: "Frankfurt", measuredPingMs: 99, reportedPingMs: 75)
        var reading = self.reading()
        var stats = meter.sample(reading, at: 0)
        XCTAssertNil(stats.livePingMs); XCTAssertEqual(stats.measuredPingMs, 99); XCTAssertEqual(stats.reportedPingMs, 75); XCTAssertEqual(stats.server, "Frankfurt")
        for (count, value) in [100.0, 104.4, 300, 102, 101].enumerated() {
            reading.roundTrip = (value, UInt64(count + 1))
            stats = meter.sample(reading, at: Double(count + 1))
        }
        XCTAssertEqual(stats.livePingMs, 102, "One late acknowledgement does not move it")
        stats = meter.sample(reading, at: 7)
        XCTAssertEqual(stats.livePingMs, 102, "The same measurement read twice is one measurement")
        for count in 6...8 { reading.roundTrip = (50, UInt64(count)); stats = meter.sample(reading, at: Double(count + 2)) }
        XCTAssertEqual(stats.livePingMs, 50)
    }

    func testRecentLossesAreThoseOfTheLastThreeSeconds() {
        var meter = StreamMeter()
        var stats = meter.sample(reading(lost: 2, failures: 1), at: 0)
        XCTAssertEqual(stats.recentLostFrames, 0); XCTAssertEqual(stats.lostFrames, 2)
        stats = meter.sample(reading(lost: 5, failures: 2), at: 0.5)
        XCTAssertEqual(stats.recentLostFrames, 3); XCTAssertEqual(stats.recentFailures, 1)
        for step in 2...7 { stats = meter.sample(reading(lost: 5, failures: 2), at: Double(step) / 2) }
        XCTAssertEqual(stats.recentLostFrames, 0, "Trouble that is over is not shown as going on")
        XCTAssertEqual(stats.lostFrames, 5)
    }

    func testTheCodecIsNamedByWhatTheDecoderSeesAndTheDelayByTheDisplay() {
        XCTAssertEqual(StreamMeter.codecName(0x68766331, askedHEVC: false), "H.265 (HEVC)")
        XCTAssertEqual(StreamMeter.codecName(0x68657631, askedHEVC: false), "H.265 (HEVC)")
        XCTAssertEqual(StreamMeter.codecName(0x61766331, askedHEVC: true), "H.264 (AVC)")
        XCTAssertEqual(StreamMeter.codecName(0, askedHEVC: true), "H.265 (HEVC)", "Until the decoder has a stream, what was asked for")
        XCTAssertEqual(StreamMeter.codecName(0, askedHEVC: false), "H.264 (AVC)")
        var meter = StreamMeter()
        var reading = self.reading()
        reading.video.decodeMs = 4; reading.video.presentationMs = 21; reading.video.addedDelayMs = 8; reading.displayHz = 60
        reading.video.width = 1920; reading.video.height = 1080; reading.video.generation = .active
        reading.audioReceived = 7; reading.hapticPackets = 3; reading.triggerPackets = 2; reading.hapticPlayed = 1
        let stats = meter.sample(reading, at: 0)
        XCTAssertEqual(stats.screenDelayMs, reading.video.screenDelayMs(displayRate: 60))
        let expected: Double = 35 + 1000.0 / 120
        XCTAssertEqual(stats.screenDelayMs, expected, accuracy: 0.001)
        XCTAssertEqual(stats.displayHz, 60); XCTAssertEqual(stats.generation, .active); XCTAssertEqual(stats.addedDelayMs, 8)
        XCTAssertEqual([stats.width, stats.height, stats.audioReceived, stats.hapticPackets, stats.triggerPackets, stats.hapticPlayed], [1920, 1080, 7, 3, 2, 1])
        XCTAssertEqual(stats.health["width"] as? Int, 1920)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(stats.health))
        XCTAssertNil(stats.health["server"], "Counts only")
    }

    func testARegistrationCodeIsEightDigitsHoweverTheyWereTyped() {
        XCTAssertEqual(StreamText.registrationPIN("12345678"), 12345678)
        XCTAssertEqual(StreamText.registrationPIN("1234 5678"), 12345678)
        XCTAssertEqual(StreamText.registrationPIN("0000-0042"), 42)
        XCTAssertNil(StreamText.registrationPIN("1234567"))
        XCTAssertNil(StreamText.registrationPIN("123456789"))
        XCTAssertNil(StreamText.registrationPIN(""))
    }

    func testTheEngineReasonsOfAnEndAreShownInTheAppsWordsAndTheServersOwnAreKept() {
        XCTAssertEqual(StreamText.quitReason("Stream: unknown error"), loc("Stream: unknown error"))
        XCTAssertEqual(StreamText.quitReason("Stream: remote disconnected: Remote Play is used elsewhere"), loc("Stream: the server disconnected") + ": Remote Play is used elsewhere")
        XCTAssertEqual(StreamText.quitReason("Session request: remote play in use"), loc("Session request: Remote Play is already in use"))
        XCTAssertEqual(StreamText.quitReason("Stopped"), loc("Stopped"))
        XCTAssertEqual(StreamText.quitReason("the line dropped"), "the line dropped", "Words that are not the engine's reasons stay as they are")
        XCTAssertEqual(StreamText.quitNames.count, 13)
        XCTAssertTrue(StreamText.quitNames.allSatisfy { StreamText.quitName($0) != nil })
    }

    func testTheEndOfAConsoleStreamIsAFailureOrAStatus() {
        XCTAssertEqual(StreamText.ended(reason: "boom", isError: true).failure, "boom")
        XCTAssertNil(StreamText.ended(reason: "boom", isError: true).status)
        let quiet = StreamText.ended(reason: "Stopped", isError: false)
        XCTAssertNil(quiet.failure)
        XCTAssertEqual(quiet.status, Localization.text("Session ended: %@", values: ["Stopped"], in: .english))
        XCTAssertNotEqual(StreamText.describe(EngineError.invalidCredentials), StreamText.describe(EngineError.cancelled))
        XCTAssertEqual(StreamText.describe(EngineError.engine(code: 1, message: "Odd thing")), "Odd thing", "The engine's own words, when it has any")
        XCTAssertFalse(StreamText.describe(EngineError.engine(code: 1, message: "")).isEmpty)
        XCTAssertFalse(StreamText.describe(URLError(.timedOut)).isEmpty)
    }

    func testOnlyLinesAboutTheMediaAreKeptOfTheEnginesLog() {
        XCTAssertTrue(StreamText.isMediaDiagnostic("audio header: 2 channels, 48000 Hz"))
        XCTAssertTrue(StreamText.isMediaDiagnostic("audio: 480 samples"))
        XCTAssertFalse(StreamText.isMediaDiagnostic("takion: received key 0011"))
        XCTAssertTrue(StreamText.isConnectionDiagnostic("transport: receiving: connection reset"))
        XCTAssertTrue(StreamText.isConnectionDiagnostic("session: server disconnected"))
        XCTAssertFalse(StreamText.isConnectionDiagnostic("takion: received key 0011"))
        XCTAssertFalse(StreamText.isMediaDiagnostic("launchSpec: audio header:"), "By how the line begins")
    }

    func testAnEventForTheGamepadIsItsReport() {
        var rumble = DualSenseReport(); rumble.rumble(left: 200, right: 100)
        XCTAssertEqual(DualSenseReport(.rumble(left: 200, right: 100))?.effects, rumble.effects)
        var light = DualSenseReport(); light.light(red: 0, green: 0, blue: 0)
        XCTAssertEqual(DualSenseReport(.led(red: 0, green: 0, blue: 0))?.effects, light.effects, "Black becomes Con's own color")
        var player = DualSenseReport(); player.player(2)
        XCTAssertEqual(DualSenseReport(.playerIndex(2))?.effects, player.effects)
        let effect = [UInt8](repeating: 7, count: 11)
        var triggers = DualSenseReport(); triggers.triggers(left: effect, right: effect)
        XCTAssertEqual(DualSenseReport(.triggerEffects(left: effect, right: effect))?.effects, triggers.effects)
        XCTAssertNil(DualSenseReport(.connected)); XCTAssertNil(DualSenseReport(.haptics(Data([1, 2]))))
        XCTAssertNil(DualSenseReport(.motionReset)); XCTAssertNil(DualSenseReport(.effectIntensity(trigger: true, value: 1)))
    }

    func testOnlyTheMotorsAndTheSoundHapticsAreVibration() {
        XCTAssertTrue(RemotePlaySession.Event.rumble(left: 1, right: 1).isVibration)
        XCTAssertTrue(RemotePlaySession.Event.haptics(Data([1, 2, 3, 4])).isVibration)
        let effect = [UInt8](repeating: 7, count: 11)
        let others: [RemotePlaySession.Event] = [.triggerEffects(left: effect, right: effect), .led(red: 1, green: 2, blue: 3), .playerIndex(1), .connected, .motionReset,
                                                 .effectIntensity(trigger: false, value: 1), .loginPINRequired(incorrect: false), .quit(reason: "", isError: false)]
        for event in others { XCTAssertFalse(event.isVibration, "\(event)") }
    }

    func testTheOrientationIsCountedFromWhereTheGamepadWasHeld() {
        typealias Rotation = MotionReference.Rotation
        func rotation(angle: Double, axis: (Double, Double, Double)) -> Rotation {
            let length = (axis.0 * axis.0 + axis.1 * axis.1 + axis.2 * axis.2).squareRoot(), s = sin(angle / 2) / length
            return .init(x: axis.0 * s, y: axis.1 * s, z: axis.2 * s, w: cos(angle / 2))
        }
        func turned(_ a: Rotation, by b: Rotation) -> Rotation {
            .init(x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y, y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
                  z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w, w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z)
        }
        var motion = MotionReference()
        let held = rotation(angle: 0.7, axis: (0.2, 1, -0.4))
        XCTAssertEqual(motion.relative(held), held, "Before a start is set the orientation is as it is")
        motion.reset(to: held)
        let same = motion.relative(held)
        XCTAssertEqual(same.w, 1, accuracy: 1e-12); XCTAssertEqual(same.x, 0, accuracy: 1e-12)
        XCTAssertEqual(same.y, 0, accuracy: 1e-12); XCTAssertEqual(same.z, 0, accuracy: 1e-12)
        let turns: [(Double, (Double, Double, Double))] = [(0.3, (1, 0, 0)), (2.5, (0.3, -0.8, 0.5)), (-1.1, (0, 0, 1))]
        for (angle, axis) in turns {
            let now = rotation(angle: angle, axis: axis), back = turned(held, by: motion.relative(now))
            XCTAssertEqual(back.x, now.x, accuracy: 1e-12); XCTAssertEqual(back.y, now.y, accuracy: 1e-12)
            XCTAssertEqual(back.z, now.z, accuracy: 1e-12); XCTAssertEqual(back.w, now.w, accuracy: 1e-12)
        }
    }

    #if canImport(simd)
    func testTheOrientationIsWhatApplesOwnQuaternionsGive() {
        func rotation(_ q: simd_quatd) -> MotionReference.Rotation { .init(x: q.vector.x, y: q.vector.y, z: q.vector.z, w: q.vector.w) }
        var motion = MotionReference()
        let held = simd_quatd(angle: 0.7, axis: simd_normalize(SIMD3(0.2, 1, -0.4)))
        motion.reset(to: rotation(held))
        for (angle, axis) in [(0.3, SIMD3(1.0, 0, 0)), (2.5, SIMD3(0.3, -0.8, 0.5)), (-1.1, SIMD3(0, 0, 1))] {
            let now = simd_quatd(angle: angle, axis: simd_normalize(axis))
            let expected = (held.inverse * now).vector, got = motion.relative(rotation(now))
            XCTAssertEqual(got.x, expected.x, accuracy: 1e-12); XCTAssertEqual(got.y, expected.y, accuracy: 1e-12)
            XCTAssertEqual(got.z, expected.z, accuracy: 1e-12); XCTAssertEqual(got.w, expected.w, accuracy: 1e-12)
        }
    }
    #endif
}
