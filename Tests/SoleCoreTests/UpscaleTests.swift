import XCTest
@testable import SoleCore

final class UpscaleTests: XCTestCase {
    func testAPictureIsEnlargedByTheFactorChosen() {
        XCTAssertTrue(Upscale.size(picture: (1920, 1080), amount: .double)! == (3840, 2160))
        XCTAssertTrue(Upscale.size(picture: (1920, 1080), amount: .triple)! == (5760, 3240))
        XCTAssertTrue(Upscale.size(picture: (1920, 1080), amount: .quadruple)! == (7680, 4320))
        XCTAssertTrue(Upscale.size(picture: (1280, 720), amount: .triple)! == (3840, 2160))
        XCTAssertNil(Upscale.size(picture: (0, 0), amount: .double))
    }

    func testAPictureIsEnlargedToEightKAtMost() {
        XCTAssertTrue(Upscale.size(picture: (2560, 1440), amount: .quadruple)! == (7680, 4320))
        XCTAssertNil(Upscale.size(picture: (7680, 4320), amount: .double))
    }

    func testChoicesCycleAndUnknownStoredAmountsFallBackToDouble() {
        XCTAssertEqual(Upscale.Amount.double.next, .triple)
        XCTAssertEqual(Upscale.Amount.triple.next, .quadruple)
        XCTAssertEqual(Upscale.Amount.quadruple.next, .double)
        XCTAssertEqual(Upscale.Method.fsr.next(in: [.fsr, .anime4k, .metalFX]), .anime4k)
        XCTAssertEqual(Upscale.Method.metalFX.next(in: [.fsr, .anime4k, .metalFX]), .fsr)
        XCTAssertEqual(Upscale.Method.metalFX.used(in: [.fsr, .nis, .anime4k]), .fsr)
        XCTAssertEqual(Upscale.Method.nis.used(in: [.fsr, .nis, .anime4k]), .nis)
        XCTAssertEqual(Upscale.Amount.stored("1.5"), .double)
        XCTAssertEqual(Upscale.Amount.stored("window"), .double)
        XCTAssertEqual(Upscale.Amount.stored(nil), .double)
        XCTAssertEqual(Upscale.Amount.stored("4"), .quadruple)
    }
}
