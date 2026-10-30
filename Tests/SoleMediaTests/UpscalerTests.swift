import CoreVideo
import XCTest
@testable import SoleMedia
import SoleCore

final class UpscalerTests: XCTestCase {
    private func picture(width: Int, height: Int) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any], kCVPixelBufferMetalCompatibilityKey as String: true]
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes as CFDictionary, &made), kCVReturnSuccess)
        let buffer = try XCTUnwrap(made)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), chromaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for y in 0..<height { for x in 0..<width { luma[y * lumaRow + x] = 126 } }
        for y in 0..<height / 2 {
            for x in 0..<width / 2 {
                let bar = x >= width / 2 * 3 / 8 && x < width / 2 * 5 / 8
                chroma[y * chromaRow + 2 * x] = bar ? 102 : 128
                chroma[y * chromaRow + 2 * x + 1] = bar ? 240 : 128
            }
        }
        return buffer
    }

    private func makeUpscaler() throws -> Upscaler {
        do { return try Upscaler() } catch { throw XCTSkip("No Metal on this Mac: \(error)") }
    }

    func testAPictureIsEnlargedInItsColoursEachWay() throws {
        let upscaler = try makeUpscaler()
        let source = try picture(width: 640, height: 360)
        for method in [Upscale.Method.fsr, .anime4k, .metalFX] {
            for (width, height) in [(1280, 720), (1920, 1080), (2560, 1440), (960, 540), (640, 360)] {
                let out = try XCTUnwrap(upscaler.scale(source, width: width, height: height, method: method), "\(method) \(width)")
                XCTAssertEqual(CVPixelBufferGetWidth(out), width); XCTAssertEqual(CVPixelBufferGetHeight(out), height)
                XCTAssertEqual(CVPixelBufferGetPixelFormatType(out), kCVPixelFormatType_32BGRA)
                CVPixelBufferLockBaseAddress(out, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(out, .readOnly) }
                let pixels = CVPixelBufferGetBaseAddress(out)!.assumingMemoryBound(to: UInt8.self), row = CVPixelBufferGetBytesPerRow(out)
                func pixel(_ x: Int, _ y: Int) -> (b: Int, g: Int, r: Int) { let p = pixels + y * row + x * 4; return (Int(p[0]), Int(p[1]), Int(p[2])) }
                let grey = pixel(width / 8, height / 2), expected = Int(((126.0 - 16) / 219 * 255).rounded())
                XCTAssertLessThanOrEqual(abs(grey.r - expected), method == .anime4k ? 8 : 3, "\(method) \(width): \(grey)")
                XCTAssertLessThanOrEqual(abs(grey.g - grey.r), 3); XCTAssertLessThanOrEqual(abs(grey.b - grey.r), 3)
                let bar = pixel(width / 2, height / 2)
                XCTAssertGreaterThan(bar.r, bar.g + 60, "\(method) \(width): \(bar)"); XCTAssertGreaterThan(bar.r, bar.b + 20, "\(method) \(width): \(bar)")
            }
        }
    }

    func testThePictureFollowsTheSizeAskedFor() throws {
        let upscaler = try makeUpscaler()
        let source = try picture(width: 640, height: 360)
        XCTAssertEqual(upscaler.scale(source, width: 1280, height: 720).map(CVPixelBufferGetWidth), 1280)
        XCTAssertEqual(upscaler.scale(source, width: 1920, height: 1080).map(CVPixelBufferGetWidth), 1920)
        XCTAssertEqual(upscaler.scale(source, width: 1280, height: 720).map(CVPixelBufferGetHeight), 720)
    }

    func testPicturesOfTwoSizesInTurnAndAfterALetGoAreEnlarged() throws {
        let upscaler = try makeUpscaler()
        let real = try picture(width: 640, height: 360), generated = try picture(width: 320, height: 180)
        for method in [Upscale.Method.fsr, .anime4k, .metalFX] {
            for _ in 0..<3 {
                XCTAssertEqual(upscaler.scale(real, width: 1280, height: 720, method: method).map(CVPixelBufferGetHeight), 720, "\(method)")
                XCTAssertEqual(upscaler.scale(generated, width: 640, height: 360, method: method).map(CVPixelBufferGetHeight), 360, "\(method)")
            }
            upscaler.release()
        }
        XCTAssertEqual(upscaler.scale(real, width: 1920, height: 1080).map(CVPixelBufferGetWidth), 1920)
    }
}
