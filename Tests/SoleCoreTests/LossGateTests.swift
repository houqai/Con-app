import XCTest
@testable import SoleCore

final class LossGateTests: XCTestCase {
    private func unit(keyframe: Bool = false, picture: Bool = true) -> VideoStream.Unit {
        var unit = VideoStream.Unit()
        if picture { unit.slices = [[0x41, 0x9A, 0x01][...]] }
        unit.isKeyframe = keyframe
        return unit
    }
    private func take(_ gate: inout LossGate, _ unit: VideoStream.Unit, _ frame: Int) -> LossGate.Decision {
        let decision = gate.take(unit, frame: frame)
        if case .decode = decision { gate.decoded(true) }
        return decision
    }

    func testNothingButAKeyframeStartsTheDecoder() {
        var gate = LossGate()
        XCTAssertEqual(take(&gate, unit(), 1), .skip)
        XCTAssertEqual(take(&gate, unit(picture: false), 2), .decode, "Parameter sets always go")
        XCTAssertEqual(take(&gate, unit(keyframe: true), 3), .decode)
        XCTAssertEqual(take(&gate, unit(), 4), .decode)
    }

    func testAFrameTheDecoderDidNotTakeIsALossToo() {
        var gate = LossGate()
        _ = take(&gate, unit(keyframe: true), 1)
        XCTAssertEqual(gate.take(unit(), frame: 2), .decode)
        gate.decoded(false)
        XCTAssertEqual(take(&gate, unit(), 3), .skip)
        gate.restart()
        XCTAssertEqual(take(&gate, unit(), 4), .skip, "A decoder started anew holds nothing")
        XCTAssertEqual(take(&gate, unit(keyframe: true), 5), .decode)
    }

    func testTheCounterWrapsAndAMissingCounterIsNoLoss() {
        var gate = LossGate()
        _ = take(&gate, unit(keyframe: true), 0xFFFF)
        XCTAssertEqual(take(&gate, unit(), 0), .decode)
        XCTAssertEqual(gate.take(unit(), frame: nil), .decode)
    }

    private func parameters() -> VideoStream.Unit {
        var unit = unit(picture: false)
        unit.carriesParameters = true
        return unit
    }
    private let sets: [[UInt8]] = [[0x40, 0x01], [0x42, 0x01], [0x44, 0x01]]

    func testNothingIsHeldAfterLostFrames() {
        var gate = LossGate()
        XCTAssertEqual(gate.take(parameters(), frame: nil), .decode, "Parameter sets come as frame -1, without a counter")
        gate.decoded(true)
        XCTAssertEqual(take(&gate, unit(keyframe: true), 0), .decode)
        for frame in 1...20 { XCTAssertEqual(take(&gate, unit(), frame), .decode) }
        XCTAssertEqual(take(&gate, unit(), 29), .decode, "A gap is the engine's call, not ours")
        XCTAssertEqual(gate.missing, 8, "Still counted in the stats")
        for frame in 30...40 { XCTAssertEqual(take(&gate, unit(), frame), .decode); XCTAssertEqual(gate.missing, 0) }
        XCTAssertEqual(take(&gate, unit(), 0xFFFF), .decode, "Nor after a long gap")
        XCTAssertEqual(take(&gate, unit(), 1), .decode, "The counter wraps")
        XCTAssertEqual(gate.missing, 1)
        XCTAssertTrue(gate.parametersFirst.isEmpty)
    }

    func testPicturesTheEngineHidesAreNoLoss() {
        var gate = LossGate()
        XCTAssertEqual(take(&gate, unit(keyframe: true), 1320), .decode)
        for frame in 1321...1324 { XCTAssertEqual(take(&gate, unit(), frame), .decode) }
        XCTAssertEqual(take(&gate, unit(), 1327), .decode)
        XCTAssertEqual(gate.missing, 2, "Only the two that never came")
        for frame in 1328...1335 {
            XCTAssertEqual(take(&gate, unit(), frame), .decode, "frame \(frame)")
            XCTAssertEqual(gate.missing, 0, "A hidden picture is not a lost one")
        }
        for frame in 1336...1340 { XCTAssertEqual(take(&gate, unit(), frame), .decode); XCTAssertEqual(gate.missing, 0) }
        XCTAssertTrue(gate.parametersFirst.isEmpty)
    }

    func testAPictureTheDecoderDidNotTakeHoldsTheStreamUntilAKeyframe() {
        var gate = LossGate()
        _ = take(&gate, unit(keyframe: true), 1)
        XCTAssertEqual(gate.take(unit(), frame: 2), .decode)
        gate.decoded(false)
        XCTAssertEqual(take(&gate, unit(), 3), .skip)
        XCTAssertEqual(take(&gate, unit(), 4), .skip)
        XCTAssertEqual(gate.take(parameters(), frame: nil), .decode, "Parameter sets always go")
        gate.decoded(true)
        XCTAssertEqual(take(&gate, unit(keyframe: true), 5), .decode)
        XCTAssertEqual(take(&gate, unit(), 6), .decode)
        XCTAssertEqual(gate.take(parameters(), frame: nil), .decode)
        gate.decoded(false)
        XCTAssertEqual(take(&gate, unit(), 7), .decode)
    }

    func testADecoderStartedAnewWaitsForAKeyframeAndIsSetUpBeforeIt() {
        var gate = LossGate()
        XCTAssertEqual(take(&gate, unit(), 1), .skip, "Nothing before the first keyframe")
        XCTAssertEqual(gate.take(parameters(), parameterSets: sets, frame: nil), .decode)
        gate.decoded(true)
        XCTAssertEqual(gate.take(unit(keyframe: true), parameterSets: sets, frame: 2), .decode)
        XCTAssertTrue(gate.parametersFirst.isEmpty, "The decoder has them already")
        gate.decoded(true)

        gate.restart()
        XCTAssertEqual(gate.take(unit(), parameterSets: sets, frame: 3), .skip)
        XCTAssertEqual(gate.take(unit(keyframe: true), parameterSets: sets, frame: 4), .decode)
        XCTAssertEqual(gate.parametersFirst, sets, "Parameter sets sent before the restart are prepended")
        gate.decoded(true)
        XCTAssertEqual(gate.take(unit(), parameterSets: sets, frame: 5), .decode)
        XCTAssertTrue(gate.parametersFirst.isEmpty)
        gate.decoded(true)
        XCTAssertEqual(gate.take(unit(keyframe: true), parameterSets: sets, frame: 6), .decode)
        XCTAssertTrue(gate.parametersFirst.isEmpty, "Prepended only once")
        gate.decoded(true)

        gate.restart()
        var own = unit(keyframe: true)
        own.carriesParameters = true
        XCTAssertEqual(gate.take(own, parameterSets: sets, frame: 7), .decode)
        XCTAssertTrue(gate.parametersFirst.isEmpty)
        gate.decoded(true)
        gate.restart()
        _ = gate.take(unit(keyframe: true), parameterSets: sets, frame: 8)
        gate.decoded(false)
        XCTAssertEqual(gate.take(unit(keyframe: true), parameterSets: sets, frame: 9), .decode)
        XCTAssertEqual(gate.parametersFirst, sets)
    }

    func testAUnitSaysWhetherItCarriesParameterSets() {
        var stream = VideoStream(codec: .h265)
        let sets: [UInt8] = [0, 0, 0, 1, 0x40, 0x01, 0x0C, 0, 0, 0, 1, 0x42, 0x01, 0x01, 0, 0, 0, 1, 0x44, 0x01, 0xC1]
        let picture: [UInt8] = [0, 0, 0, 1, 0x26, 0x01, 0xAF]
        XCTAssertTrue(sets.withUnsafeBufferPointer { stream.read($0) }.carriesParameters)
        XCTAssertFalse(picture.withUnsafeBufferPointer { stream.read($0) }.carriesParameters)
        let both = (sets + picture).withUnsafeBufferPointer { stream.read($0) }
        XCTAssertTrue(both.carriesParameters, "Reported as carried even when unchanged")
        XCTAssertFalse(both.parametersChanged)
        XCTAssertTrue(both.isKeyframe)
        XCTAssertEqual(stream.parameterSets?.count, 3)
    }
}
