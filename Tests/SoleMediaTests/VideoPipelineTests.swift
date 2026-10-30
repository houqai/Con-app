import XCTest
import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox
@testable import SoleMedia

@MainActor final class VideoPipelineTests: XCTestCase {
    func testDecodesAndShowsEveryReceivedFrame() async throws {
        var clock = FrameClock()
        let units = try Self.encode(frames: 12)
        let pipeline = VideoPipeline(codec: .h265, layer: AVSampleBufferDisplayLayer())
        try await feed(units, to: pipeline, clock: &clock)
        try await Task.sleep(nanoseconds: 300_000_000)
        let stats = pipeline.snapshot()
        XCTAssertEqual(stats.receivedFrames, 12)
        XCTAssertEqual(stats.shownFrames, 12)
        XCTAssertEqual(stats.generatedFrames, 0)
        XCTAssertEqual(stats.decodeFailures, 0)
        XCTAssertEqual(stats.width, 1280); XCTAssertEqual(stats.height, 720)
        XCTAssertEqual(stats.generation, .off)
        XCTAssertGreaterThan(stats.bytes, 0)
        pipeline.invalidate()
    }

    func testDecodesHiddenPicturesWithoutShowingThem() async throws {
        var clock = FrameClock()
        let units = try Self.encode(frames: 12)
        let pipeline = VideoPipeline(codec: .h265, layer: AVSampleBufferDisplayLayer())
        for (index, unit) in units.enumerated() {
            let taken = unit.withUnsafeBufferPointer { pipeline.submit($0, frame: index, display: !(4...7).contains(index)) }
            XCTAssertTrue(taken, "Frame \(index) is decoded whether shown or not")
            try await clock.tick()
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let stats = pipeline.snapshot()
        XCTAssertEqual(stats.receivedFrames, 12)
        XCTAssertEqual(stats.hiddenFrames, 4)
        XCTAssertEqual(stats.shownFrames, 8, "Only displayed pictures reach the layer")
        XCTAssertEqual(stats.decodeFailures, 0, "Pictures after the hidden ones decode")
        XCTAssertEqual(stats.missingFrames, 0, "A hidden picture is not counted as lost")
        pipeline.invalidate()
    }

    func testCountsTheWayOfAFrameToTheDisplay() {
        var stats = VideoPipeline.Stats()
        stats.presentationMs = 21
        XCTAssertEqual(stats.screenDelayMs(displayRate: 60), 31.3, accuracy: 0.1)
        stats.presentationMs = 0
        XCTAssertEqual(stats.screenDelayMs(displayRate: 60), 23.3, accuracy: 0.1)
        stats.decodeMs = 3.6
        XCTAssertEqual(stats.screenDelayMs(displayRate: 60), 26.9, accuracy: 0.1, "Decoding comes first")
        stats.presentationMs = 21; stats.addedDelayMs = 30.7
        XCTAssertEqual(stats.screenDelayMs(displayRate: 60), 65.6, accuracy: 0.1, "A generated frame shown first delays the received one")
        stats.addedDelayMs = 0; stats.decodeMs = 0
        XCTAssertEqual(stats.screenDelayMs(displayRate: 120), 27.2, accuracy: 0.1, "A faster display adds less refresh delay")
        XCTAssertEqual(stats.screenDelayMs(displayRate: 0), stats.screenDelayMs(displayRate: 60), "An unknown display is treated as 60 Hz")
    }

    func testKnowsHowFarAheadPicturesAreTimed() async throws {
        var clock = FrameClock()
        let units = try Self.encode(frames: 150)
        let pipeline = VideoPipeline(codec: .h265, layer: AVSampleBufferDisplayLayer())
        try await feed(units.prefix(90), to: pipeline, clock: &clock)
        let even = pipeline.snapshot().presentationMs
        XCTAssertTrue((12...32).contains(even), "Close to the presentation clock lead: \(even) ms")
        pipeline.presentationLead = 0
        try await feed(units.suffix(60), to: pipeline, clock: &clock)
        XCTAssertLessThan(pipeline.snapshot().presentationMs, 1.5, "Pictures timed at arrival are not delayed")
        pipeline.invalidate()
    }

    func testGeneratesFramesBetweenReceivedOnesAndStopsWhenTurnedOff() async throws {
        guard VideoPipeline.generationSupported else { throw XCTSkip("Native interpolation unavailable") }
        var clock = FrameClock()
        let units = try Self.encode(frames: 240)
        let pipeline = VideoPipeline(codec: .h265, layer: AVSampleBufferDisplayLayer())
        pipeline.displayRate = 120
        pipeline.frameGeneration = true
        var afterWarmUp = VideoPipeline.Stats()
        for (index, unit) in units.prefix(180).enumerated() {
            if index == 120 { afterWarmUp = pipeline.snapshot() }
            _ = unit.withUnsafeBufferPointer { pipeline.submit($0) }
            try await clock.tick()
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        let generating = pipeline.snapshot()
        XCTAssertGreaterThanOrEqual(generating.generatedFrames - afterWarmUp.generatedFrames, 40, "generated \(generating.generatedFrames - afterWarmUp.generatedFrames) of 60, \(generating.generationMs) ms each")
        XCTAssertGreaterThan(generating.addedDelayMs, 0)
        XCTAssertEqual(generating.generation, .active)
        XCTAssertEqual(generating.shownFrames, generating.newFrames, "Only distinct game pictures are shown")
        XCTAssertLessThanOrEqual(generating.generatedFrames, 179)
        XCTAssertGreaterThan(generating.generationMs, 0)

        pipeline.frameGeneration = false
        try await feed(units.suffix(60), to: pipeline, clock: &clock)
        try await Task.sleep(nanoseconds: 200_000_000)
        let plain = pipeline.snapshot()
        XCTAssertEqual(plain.generation, .off)
        XCTAssertEqual(plain.addedDelayMs, 0)
        XCTAssertEqual(plain.shownFrames + plain.suppressedRepeats + plain.lateFrames, plain.receivedFrames, "Every picture is shown unless a generated frame replaced it")
        XCTAssertEqual(plain.suppressedRepeats, generating.suppressedRepeats, "No repeats are suppressed once generation is off")
        XCTAssertLessThanOrEqual(plain.generatedFrames - generating.generatedFrames, 1)
        pipeline.invalidate()
    }

    func testGeneratesNothingAndHoldsNothingBackWhenTheDisplayIsAsFastAsTheGame() async throws {
        var clock = FrameClock()
        let units = try Self.encode(frames: 120)
        let loaded = Counter()
        let pipeline = VideoPipeline(codec: .h265, layer: AVSampleBufferDisplayLayer()) { loaded.add(); return StandIn(failing: false) }
        pipeline.frameGeneration = true
        try await feed(units, to: pipeline, clock: &clock)
        try await Task.sleep(nanoseconds: 200_000_000)
        let stats = pipeline.snapshot()
        XCTAssertEqual(stats.generation, .standby)
        XCTAssertEqual(stats.generatedFrames, 0)
        XCTAssertEqual(stats.addedDelayMs, 0)
        XCTAssertEqual(stats.shownFrames + stats.lateFrames, stats.receivedFrames, "Every picture is shown")
        XCTAssertEqual(stats.suppressedRepeats, 0)
        XCTAssertGreaterThanOrEqual(stats.shownFrames, 110)
        XCTAssertEqual(loaded.value, 0, "The generator is not loaded while it is not needed")
        pipeline.invalidate()
    }

    func testPreparesTheGeneratorAgainWhenTheHeightOfItsFrameIsChanged() async throws {
        var clock = FrameClock()
        let units = try Self.encode(frames: 120)
        let generator = StandIn(failing: false)
        let pipeline = VideoPipeline(codec: .h265, layer: AVSampleBufferDisplayLayer()) { generator }
        pipeline.displayRate = 120
        pipeline.frameGeneration = true
        XCTAssertEqual(pipeline.generationHeight, 720, "The default height suits the slowest Macs")
        for (index, unit) in units.enumerated() {
            if index == 60 { pipeline.generationHeight = 1080 }
            _ = unit.withUnsafeBufferPointer { pipeline.submit($0) }
            try await clock.tick()
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(generator.prepared, [720, 1080])
        XCTAssertEqual(pipeline.snapshot().generation, .active)
        XCTAssertGreaterThan(generator.requests, 80, "Generation goes on at the new height")
        pipeline.generationHeight = 0
        XCTAssertEqual(pipeline.generationHeight, 1080, "An invalid height is ignored")
        pipeline.invalidate()
    }

    func testGivesUpAGeneratorThatKeepsFailingAndStopsHoldingPicturesBack() async throws {
        var clock = FrameClock()
        let units = try Self.encode(frames: 180)
        let generator = StandIn(failing: true)
        let pipeline = VideoPipeline(codec: .h265, layer: AVSampleBufferDisplayLayer()) { generator }
        pipeline.displayRate = 120
        pipeline.frameGeneration = true
        try await feed(units.prefix(120), to: pipeline, clock: &clock)
        try await Task.sleep(nanoseconds: 200_000_000)
        let failed = pipeline.snapshot()
        XCTAssertEqual(failed.generation, .unavailable)
        XCTAssertEqual(failed.addedDelayMs, 0, "Nothing to wait for")
        XCTAssertEqual(failed.generatedFrames, 0)
        XCTAssertEqual(generator.requests, VideoPipeline.failuresToGiveUp, "Not called again after it is given up")
        XCTAssertTrue(generator.ended)
        XCTAssertGreaterThanOrEqual(failed.shownFrames, 110, "shown \(failed.shownFrames) of 120")

        pipeline.frameGeneration = false
        try await feed(units.dropFirst(120).prefix(10), to: pipeline, clock: &clock)
        XCTAssertEqual(pipeline.snapshot().generation, .off)
        pipeline.frameGeneration = true
        try await feed(units.suffix(50), to: pipeline, clock: &clock)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(pipeline.snapshot().generation, .unavailable)
        XCTAssertEqual(generator.requests, 2 * VideoPipeline.failuresToGiveUp)
        pipeline.invalidate()
    }

    func testAPictureThatStandsStillKeepsBeingShown() async throws {
        var clock = FrameClock()
        let units = try Self.encode(frames: 120, stillAfter: 20)
        let pipeline = VideoPipeline(codec: .h265, layer: AVSampleBufferDisplayLayer())
        try await feed(units, to: pipeline, clock: &clock)
        try await Task.sleep(nanoseconds: 300_000_000)
        let stats = pipeline.snapshot()
        XCTAssertLessThanOrEqual(stats.newFrames, 24, "The picture moved for the first twenty frames only")
        XCTAssertGreaterThanOrEqual(stats.shownFrames, 114, "Every frame is still shown: \(stats.shownFrames) of 120")
        XCTAssertEqual(stats.suppressedRepeats, 0)
        pipeline.invalidate()
    }

    func testWithGenerationAStillPictureIsShownAgainAfterAShortPause() async throws {
        var clock = FrameClock()
        let units = try Self.encode(frames: 150, stillAfter: 60)
        let generator = StandIn(failing: false)
        let pipeline = VideoPipeline(codec: .h265, layer: AVSampleBufferDisplayLayer()) { generator }
        pipeline.displayRate = 120
        pipeline.frameGeneration = true
        var moving = VideoPipeline.Stats()
        for (index, unit) in units.enumerated() {
            if index == 61 { moving = pipeline.snapshot() }
            _ = unit.withUnsafeBufferPointer { pipeline.submit($0) }
            try await clock.tick()
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let stats = pipeline.snapshot()
        XCTAssertGreaterThan(moving.addedDelayMs, 0, "Frames were being generated while the picture moved")
        XCTAssertEqual(moving.suppressedRepeats, 0)
        let still = stats.shownFrames - moving.shownFrames, left = stats.suppressedRepeats
        XCTAssertTrue((3...10).contains(left), "Repeats are suppressed for the first tenth of a second: \(left)")
        XCTAssertGreaterThanOrEqual(still, 72, "Then every frame is shown again: \(still) of 89")
        pipeline.invalidate()
    }

    func testCountsPicturesOfAGameThatRendersThirtyAndGeneratesBetweenThem() async throws {
        var clock = FrameClock()
        let units = try Self.encode(frames: 300, repeating: 2)
        let pipeline = VideoPipeline(codec: .h265, layer: AVSampleBufferDisplayLayer())
        try await feed(units.prefix(60), to: pipeline, clock: &clock)
        let plain = pipeline.snapshot()
        XCTAssertEqual(plain.receivedFrames, 60)
        try await Task.sleep(nanoseconds: 100_000_000)
        let settled = pipeline.snapshot()
        XCTAssertTrue((57...60).contains(settled.shownFrames), "Every picture is shown, including the second copy of each: \(settled.shownFrames)")
        XCTAssertEqual(settled.suppressedRepeats, 0)
        XCTAssertTrue((29...31).contains(plain.newFrames), "new pictures: \(plain.newFrames)")
        XCTAssertEqual(plain.codec, kCMVideoCodecType_HEVC)
        XCTAssertNotNil(plain.hardwareDecoder)

        guard VideoPipeline.generationSupported else { pipeline.invalidate(); return }
        pipeline.frameGeneration = true
        var afterWarmUp = VideoPipeline.Stats()
        for (index, unit) in units.dropFirst(60).enumerated() {
            if index == 120 { afterWarmUp = pipeline.snapshot() }
            _ = unit.withUnsafeBufferPointer { pipeline.submit($0) }
            try await clock.tick()
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let generating = pipeline.snapshot()
        XCTAssertEqual(generating.generation, .active)
        let pictures = generating.newFrames - afterWarmUp.newFrames
        let generated = generating.generatedFrames - afterWarmUp.generatedFrames
        XCTAssertTrue((59...61).contains(pictures), "new pictures in two seconds: \(pictures)")
        XCTAssertGreaterThanOrEqual(generated, 45, "generated \(generated) for \(pictures) pictures")
        XCTAssertLessThanOrEqual(generated, pictures)
        let originals = generating.shownFrames - afterWarmUp.shownFrames
        XCTAssertTrue((59...61).contains(originals), "30 original pictures per second: \(originals)")
        XCTAssertLessThanOrEqual(originals + generated, 122, "30 original + 30 generated, never 90 fps")
        pipeline.invalidate()
    }

    func testReportsUndecodableFramesAndRecoversAtKeyframe() async throws {
        let units = try Self.encode(frames: 30, keyframes: [20])
        let pipeline = VideoPipeline(codec: .h265, layer: AVSampleBufferDisplayLayer())
        let failures = Counter()
        pipeline.onFailure = { failures.add() }
        var accepted: [Bool] = []
        for (index, unit) in units.enumerated() {
            if index == 5 { accepted.append(false); continue }
            var bytes = unit
            if index == 6 { for position in stride(from: bytes.count / 2, to: bytes.count, by: 3) { bytes[position] ^= 0x5a } }
            accepted.append(bytes.withUnsafeBufferPointer { pipeline.submit($0) })
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let stats = pipeline.snapshot()
        XCTAssertEqual(Array(accepted.prefix(5)), [true, true, true, true, true])
        XCTAssertEqual(Array(accepted.suffix(10)), Array(repeating: true, count: 10), "Decoding continues from the keyframe")
        XCTAssertEqual(stats.keyframes, 2)
        XCTAssertEqual(stats.decodeFailures, accepted.dropFirst(6).filter { !$0 }.count)
        XCTAssertEqual(failures.value, stats.decodeFailures)
        XCTAssertEqual(stats.shownFrames + stats.suppressedRepeats, accepted.filter { $0 }.count)
        pipeline.invalidate()
    }

    private func feed(_ units: some Sequence<[UInt8]>, to pipeline: VideoPipeline, clock: inout FrameClock) async throws {
        for unit in units {
            _ = unit.withUnsafeBufferPointer { pipeline.submit($0) }
            try await clock.tick()
        }
    }

    private struct FrameClock {
        private var next = DispatchTime.now().uptimeNanoseconds
        mutating func tick() async throws {
            next += 16_666_667
            let now = DispatchTime.now().uptimeNanoseconds
            if next > now { try await Task.sleep(nanoseconds: next - now) } else { next = now }
        }
    }

    private final class StandIn: FrameGenerator, @unchecked Sendable {
        private let lock = NSLock()
        private let failing: Bool
        private var state = (requests: 0, ended: false, prepared: [Int]())
        init(failing: Bool) { self.failing = failing }
        var requests: Int { lock.withLock { state.requests } }
        var ended: Bool { lock.withLock { state.ended } }
        var prepared: [Int] { lock.withLock { state.prepared } }
        func configure(width: Int, height: Int, pixelFormat: OSType, limit: Int) async throws { lock.withLock { state.ended = false; state.prepared.append(limit) } }
        func interpolate(previous: sending CVPixelBuffer, current: sending CVPixelBuffer, previousTime: CMTime, currentTime: CMTime) async throws -> GeneratedFrame? {
            lock.withLock { state.requests += 1 }
            if failing { throw CocoaError(.featureUnsupported) }
            return GeneratedFrame(buffer: current, timestamp: currentTime)
        }
        func end() async throws { lock.withLock { state.ended = true } }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    private static func encode(frames: Int, keyframes: Set<Int> = [], repeating: Int = 1, stillAfter: Int = .max) throws -> [[UInt8]] {
        var created: VTCompressionSession?
        guard VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: 1280, height: 720, codecType: kCMVideoCodecType_HEVC, encoderSpecification: nil,
                                         imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &created) == noErr,
              let session = created else { throw XCTSkip("No HEVC encoder") }
        defer { VTCompressionSessionInvalidate(session) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 100_000 as CFNumber)
        let lock = NSLock()
        var units: [Int: [UInt8]] = [:]
        for index in 0..<frames {
            let picture = try self.picture(x: 80 + (min(index, stillAfter) / repeating % 60) * 12)
            let status = VTCompressionSessionEncodeFrame(session, imageBuffer: picture, presentationTimeStamp: CMTime(value: Int64(index), timescale: 60), duration: CMTime(value: 1, timescale: 60),
                                                         frameProperties: keyframes.contains(index) ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil, infoFlagsOut: nil) { status, _, sample in
                guard status == noErr, let sample, let unit = annexB(sample) else { return }
                lock.withLock { units[index] = unit }
            }
            XCTAssertEqual(status, noErr)
        }
        XCTAssertEqual(VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid), noErr)
        let ordered = lock.withLock { (0..<frames).compactMap { units[$0] } }
        XCTAssertEqual(ordered.count, frames)
        return ordered
    }

    nonisolated private static func annexB(_ sample: CMSampleBuffer) -> [UInt8]? {
        guard let block = CMSampleBufferGetDataBuffer(sample), let format = CMSampleBufferGetFormatDescription(sample) else { return nil }
        var unit: [UInt8] = []
        let attachments = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]])?.first
        if attachments?[kCMSampleAttachmentKey_NotSync] as? Bool != true {
            var count = 0
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let pointer else { return nil }
                unit += [0, 0, 0, 1] + Array(UnsafeBufferPointer(start: pointer, count: size))
            }
        }
        var data = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: data.count, destination: &data) == kCMBlockBufferNoErr else { return nil }
        var offset = 0
        while offset + 4 <= data.count {
            let length = Int(data[offset]) << 24 | Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            guard length > 0, offset + 4 + length <= data.count else { return nil }
            unit += [0, 0, 0, 1] + data[(offset + 4)..<(offset + 4 + length)]
            offset += 4 + length
        }
        return unit
    }

    private static func picture(x: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]]
        guard CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else { throw XCTSkip("No pixel buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            memset(CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!, plane == 0 ? 30 : 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
        let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for y in 300..<420 { for column in x..<min(x + 120, 1280) { luma[y * row + column] = 220 } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
}
