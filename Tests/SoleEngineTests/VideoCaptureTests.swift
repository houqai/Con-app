import Testing
@testable import SoleEngine

@Suite struct VideoCaptureChoiceTests {
    @Test func offUnlessAskedFor() {
        #expect(!VideoCaptureChoice.resolve(environment: [:], setting: false))
        #expect(VideoCaptureChoice.resolve(environment: [:], setting: true))
    }
    @Test func theEnvironmentWinsOverTheSetting() {
        #expect(VideoCaptureChoice.resolve(environment: ["CON_VIDEO_CAPTURE": "1"], setting: false))
        #expect(!VideoCaptureChoice.resolve(environment: ["CON_VIDEO_CAPTURE": "0"], setting: true))
        #expect(VideoCaptureChoice.resolve(environment: ["CON_VIDEO_CAPTURE": "maybe"], setting: true), "an unknown value counts as not given")
    }
    @Test func theNamesAreTheOnesDocumented() {
        #expect(VideoCaptureChoice.settingKey == "sole.videoCapture")
        #expect(VideoCaptureChoice.environmentKey == "CON_VIDEO_CAPTURE")
        #expect(VideoCaptureChoice.fileName == "video-capture.bin")
        #expect(VideoCaptureChoice.audioFileName == "audio-capture.bin")
    }
}
