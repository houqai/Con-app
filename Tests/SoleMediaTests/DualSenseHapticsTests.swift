import AVFoundation
import Foundation
import Testing
@testable import SoleMedia

@Suite struct DualSenseHapticsTests {
    @Test func actuatorAudioNeverLeaksIntoSpeakerChannels() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, interleaved: false, channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4)!)
        let buffer = try #require(DualSenseHaptics.buffer(Data([0x00, 0x40, 0x00, 0xc0, 0, 0, 0, 0]), format: format))
        let channels = try #require(buffer.floatChannelData)
        #expect(buffer.frameLength == 32)
        for frame in 0..<32 { #expect(channels[0][frame] == 0 && channels[1][frame] == 0) }
        #expect(channels[2][0] == 0.5 && channels[3][0] == -0.5)
        #expect(channels[2][8] == 0.25 && channels[3][8] == -0.25)
        #expect(channels[2][16] == 0 && channels[3][16] == 0)
        #expect(DualSenseHaptics.buffer(Data([0]), format: format) == nil)
    }
}
