import Foundation
import Testing
@testable import SoleCore

@Suite struct PictureCadenceTests {
    private func newPictures(_ changes: [Double]) -> Int {
        var cadence = PictureCadence()
        return changes.filter { cadence.isNew(change: $0) }.count
    }
    @Test func everyPictureIsNewWhenTheGameRendersSixty() {
        let smooth = [0.45, 0.64, 0.53, 0.49, 0.64, 0.66, 0.46, 0.57, 0.62, 0.57, 0.51, 0.54, 0.61, 0.57, 0.45, 0.62, 0.55, 0.48, 0.50, 0.65]
        #expect(newPictures(smooth) == smooth.count)
    }
    @Test func everySecondPictureIsARepeatWhenTheGameRendersThirty() {
        let cinematic = [0.86, 0.14, 0.87, 0.11, 0.87, 0.09, 0.90, 0.11, 0.83, 0.11, 0.89, 0.14, 0.82, 0.12, 0.89, 0.12, 0.81, 0.13, 0.91, 0.10]
        #expect(newPictures(cinematic) == 10)
        let refined = [2.01, 0.65, 2.02, 0.62, 1.93, 0.23, 1.87, 0.17, 1.90, 0.31, 1.95, 0.21, 1.93, 0.52, 1.99, 0.17]
        #expect(newPictures(refined) == 8)
    }
    @Test func aStillSceneKeepsTheRhythmOfTheGame() {
        let cinematic = [0.86, 0.14, 0.87, 0.11, 0.87, 0.09, 0.90, 0.11, 0.83, 0.11]
        let still = [0.12, 0.09, 0.11, 0.10, 0.13, 0.08, 0.10, 0.12, 0.09, 0.11, 0.10, 0.12]
        #expect(newPictures(cinematic + still) == 5 + 6)
        let smooth = [0.45, 0.64, 0.53, 0.49, 0.64, 0.66, 0.46, 0.57]
        #expect(newPictures(smooth + still) == smooth.count + still.count - 1)
        let moving = [0.62, 0.57, 0.51, 0.54, 0.61, 0.57, 0.45, 0.62]
        let expected = 5 + 6 + moving.count
        #expect((expected - 3...expected).contains(newPictures(cinematic + still + moving)))
        let refined = [2.01, 0.65, 2.02, 0.62, 1.93, 0.23, 1.87, 0.17, 1.90, 0.31, 1.95, 0.21, 1.93, 0.52, 1.99, 0.17]
        #expect(newPictures(refined + still) == 8 + 6)
    }
    @Test func stillPictureHasNoNewPictures() {
        #expect(newPictures([0.00, 0.01, 0.00, 0.01, 0.00, 0.00, 0.01, 0.00, 0.04, 0.00, 0.03, 0.00]) == 0)
    }
    @Test func sceneCutCostsAtMostOnePicture() {
        let cut = [1.12, 0.14, 1.14, 0.15, 53.93, 2.39, 1.57, 2.01, 0.65, 2.02, 0.62, 1.93, 0.23, 1.87, 0.17]
        #expect((7...8).contains(newPictures(cut)))
    }
    @Test func signaturesCompare() {
        #expect(PictureCadence.change(from: [10, 20, 30, 40], to: [10, 22, 30, 36]) == 1.5)
        #expect(PictureCadence.change(from: [], to: [1, 2]) == 255)
        #expect(PictureCadence.change(from: [1], to: []) == 255)
    }
}

@Suite struct CadenceLogTests {
    @Test func picturesAreWrittenTwentyToALine() {
        let entries = (0..<25).map { String(format: "%.2f%@", Double($0) / 10, $0 % 2 == 0 ? "N" : ".") }
        let lines = CadenceLog.text(entries).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("0.00N 0.10. 0.20N"))
        #expect(lines[1].split(separator: " ").count == 5)
    }
}
