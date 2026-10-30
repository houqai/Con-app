import XCTest
import CoreMedia
import CoreVideo
import VideoToolbox
@testable import SoleMedia

final class FrameInterpolatorTests: XCTestCase {
    func testGeneratesRealFrameOnSupportedHardware() async throws {
        guard #available(macOS 26.0, *), FrameInterpolator.isSupported else { throw XCTSkip("Native interpolation unavailable") }
        let engine = FrameInterpolator()
        let format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        try await engine.configure(width: 1280, height: 720, pixelFormat: format)
        let previous = try buffer(format: format, x: 100)
        let current = try buffer(format: format, x: 140)
        let result = try await engine.interpolate(previous: previous, current: current, previousTime: .zero, currentTime: CMTime(value: 2, timescale: 120))
        let frame = try XCTUnwrap(result)
        XCTAssertEqual(CVPixelBufferGetWidth(frame.buffer), 1280)
        XCTAssertEqual(CVPixelBufferGetHeight(frame.buffer), 720)
        XCTAssertEqual(frame.timestamp.seconds, 1.0 / 120, accuracy: 0.000000001)
        XCTAssertNotNil(CVPixelBufferGetIOSurface(frame.buffer))
        CVPixelBufferLockBaseAddress(frame.buffer, .readOnly)
        let pixels = CVPixelBufferGetBaseAddressOfPlane(frame.buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRowOfPlane(frame.buffer, 0)
        XCTAssertGreaterThan(pixels[320 * row + 160], 100)
        CVPixelBufferUnlockBaseAddress(frame.buffer, .readOnly)
        let skipped = try await engine.interpolate(previous: previous, current: current, previousTime: .zero, currentTime: .zero)
        XCTAssertNil(skipped)
        try await engine.end()
        try await engine.configure(width: 1280, height: 720, pixelFormat: format)
        let restarted = try await engine.interpolate(previous: previous, current: current, previousTime: .zero, currentTime: CMTime(value: 1, timescale: 60))
        XCTAssertNotNil(restarted)
        try await engine.end()
    }

    func testComputesTheFrameAtNoMoreThanTheLimitAndKeepsTheProportions() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        func size(_ width: Int, _ height: Int) -> [Int] { let made = FrameInterpolator.workingSize(width: width, height: height); return [made.width, made.height] }
        XCTAssertEqual(size(2560, 1440), [1280, 720])
        XCTAssertEqual(size(1920, 1080), [1280, 720])
        XCTAssertEqual(size(3840, 2160), [1280, 720])
        XCTAssertEqual(size(1280, 720), [1280, 720], "Pictures within the limit keep their size")
        XCTAssertEqual(size(960, 540), [960, 540])
        XCTAssertEqual(size(3440, 1440), [1280, 536], "The wider side decides, numbers stay even")
        XCTAssertEqual(size(1920, 1200), [1152, 720])
    }

    func testTheChosenHeightAndWhatTheSystemTakesBoundTheFrame() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let weak = (side: 1920, pixels: 1920 * 1080), strong = (side: 3840, pixels: 3840 * 2160)
        func size(_ width: Int, _ height: Int, _ limit: Int, _ system: (side: Int, pixels: Int)) -> [Int] {
            let made = FrameInterpolator.workingSize(width: width, height: height, limit: limit, system: system); return [made.width, made.height]
        }
        XCTAssertEqual(size(2560, 1440, 720, weak), [1280, 720])
        XCTAssertEqual(size(2560, 1440, 1080, weak), [1920, 1080])
        XCTAssertEqual(size(2560, 1440, 1440, weak), [1920, 1080], "A height above the system limit is lowered to it")
        XCTAssertEqual(size(2560, 1440, 1440, strong), [2560, 1440], "A faster Mac works at stream resolution")
        XCTAssertEqual(size(3840, 2160, 1440, strong), [2560, 1440])
        XCTAssertEqual(size(1920, 1080, 2160, strong), [1920, 1080], "Never larger than the source")
        XCTAssertEqual(size(1920, 1088, 1080, weak), [1906, 1080], "Slightly over the system's pixel limit")
        XCTAssertEqual(size(1080, 1920, 1080, weak), [608, 1080], "A portrait picture is limited by its height")
        for (width, height) in [(1920, 1088), (2048, 1152), (2560, 1080), (1082, 1918), (3440, 1440)] {
            let made = FrameInterpolator.workingSize(width: width, height: height, limit: 2160, system: weak)
            XCTAssertLessThanOrEqual(made.width * made.height, weak.pixels, "\(width)x\(height)")
            XCTAssertLessThanOrEqual(max(made.width, made.height), weak.side, "\(width)x\(height)")
            XCTAssertEqual(made.width % 2 + made.height % 2, 0)
        }
        let heights = FrameInterpolator.heights, system = FrameInterpolator.systemLimit
        XCTAssertEqual(heights.first, 720)
        XCTAssertEqual(heights, heights.sorted())
        for height in heights.dropFirst() { XCTAssertLessThanOrEqual(height * 16 / 9 * height, system.pixels) }
        XCTAssertEqual(VideoPipeline.generationHeights, FrameInterpolator.isSupported ? heights : [720])
    }

    func testGeneratesAtTheChosenHeight() async throws {
        guard #available(macOS 26.0, *), FrameInterpolator.isSupported else { throw XCTSkip("Native interpolation unavailable") }
        let height = try XCTUnwrap(FrameInterpolator.heights.last)
        guard height > 720 else { throw XCTSkip("This Mac generates at 720p only") }
        let engine = FrameInterpolator()
        let format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        try await engine.configure(width: 2560, height: 1440, pixelFormat: format, limit: height)
        let pictures = try [200, 280].map { try buffer(format: format, x: $0, width: 2560, height: 1440) }
        let made = try await engine.interpolate(previous: pictures[0], current: pictures[1], previousTime: .zero, currentTime: CMTime(value: 1, timescale: 30))
        let frame = try XCTUnwrap(made)
        let expected = FrameInterpolator.workingSize(width: 2560, height: 1440, limit: height)
        XCTAssertEqual(CVPixelBufferGetWidth(frame.buffer), expected.width)
        XCTAssertEqual(CVPixelBufferGetHeight(frame.buffer), expected.height)
        XCTAssertGreaterThan(CVPixelBufferGetHeight(frame.buffer), 720)
        try await engine.end()
    }

    func testGeneratesFromReducedCopiesOfLargePictures() async throws {
        guard #available(macOS 26.0, *), FrameInterpolator.isSupported else { throw XCTSkip("Native interpolation unavailable") }
        let engine = FrameInterpolator()
        let format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        try await engine.configure(width: 2560, height: 1440, pixelFormat: format)
        let pictures = try [200, 280, 360].map { try buffer(format: format, x: $0, width: 2560, height: 1440) }
        for picture in pictures { CVBufferSetAttachment(picture, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate) }
        let first = try await engine.interpolate(previous: pictures[0], current: pictures[1], previousTime: .zero, currentTime: CMTime(value: 1, timescale: 30))
        let second = try await engine.interpolate(previous: pictures[1], current: pictures[2], previousTime: CMTime(value: 1, timescale: 30), currentTime: CMTime(value: 2, timescale: 30))
        for (frame, middle) in [(try XCTUnwrap(first), 240), (try XCTUnwrap(second), 320)] {
            XCTAssertEqual(CVPixelBufferGetWidth(frame.buffer), 1280)
            XCTAssertEqual(CVPixelBufferGetHeight(frame.buffer), 720)
            XCTAssertEqual(CVBufferCopyAttachment(frame.buffer, kCVImageBufferYCbCrMatrixKey, nil) as? String, kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String, "Keeps the source color matrix")
            CVPixelBufferLockBaseAddress(frame.buffer, .readOnly)
            let pixels = CVPixelBufferGetBaseAddressOfPlane(frame.buffer, 0)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRowOfPlane(frame.buffer, 0)
            XCTAssertGreaterThan(pixels[330 * row + (middle + 100) / 2], 100, "The block, halfway")
            XCTAssertLessThan(pixels[330 * row + (middle - 120) / 2], 60, "Left of the block")
            XCTAssertLessThan(pixels[330 * row + (middle + 320) / 2], 60, "Right of the block")
            CVPixelBufferUnlockBaseAddress(frame.buffer, .readOnly)
        }
        try await engine.end()
    }

    private func buffer(format: OSType, x: Int, width: Int = 1280, height: Int = 720) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attributes as CFDictionary, &buffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        let result = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(result, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(result) {
            let address = CVPixelBufferGetBaseAddressOfPlane(result, plane)!
            let row = CVPixelBufferGetBytesPerRowOfPlane(result, plane)
            memset(address, plane == 0 ? 20 : 128, row * CVPixelBufferGetHeightOfPlane(result, plane))
        }
        let luma = CVPixelBufferGetBaseAddressOfPlane(result, 0)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRowOfPlane(result, 0)
        let scale = width / 1280
        for y in (280 * scale)..<(380 * scale) { for column in x..<(x + 100 * scale) { luma[y * row + column] = 235 } }
        CVPixelBufferUnlockBaseAddress(result, [])
        return result
    }
}
