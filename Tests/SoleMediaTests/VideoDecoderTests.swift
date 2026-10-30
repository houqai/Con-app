import Testing
import CoreMedia
import Foundation
@testable import SoleMedia

@Suite struct VideoDecoderTests {
    @Test func sampleBufferOwnsPayloadAfterSourceMutation() throws {
        var description: CMFormatDescription?
        #expect(CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264, width: 320, height: 180, extensions: nil, formatDescriptionOut: &description) == noErr)
        let format = try #require(description)
        var source: [UInt8] = [0, 0, 0, 3, 0x65, 0xaa, 0xbb]
        let sample = try #require(VideoDecoder.makeSampleBuffer(source, format: format))
        source = Array(repeating: 0, count: source.count)
        let block = try #require(CMSampleBufferGetDataBuffer(sample))
        var stored = [UInt8](repeating: 0, count: 7)
        let status = stored.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
        #expect(status == noErr)
        #expect(stored == [0, 0, 0, 3, 0x65, 0xaa, 0xbb])
    }

    @Test func rejectsAnAccessUnitWithInvalidParameterSets() {
        for codec in [VideoDecoder.Codec.h264, .h265] {
            let decoder = VideoDecoder(codec: codec)
            let stream: [UInt8] = [0, 0, 0, 1, 0x40, 0x01, 0xAA, 0, 0, 0, 1, 0x42, 0x01, 0xBB, 0, 0, 0, 1, 0x44, 0x01, 0xCC, 0, 0, 0, 1, 0x26, 0x01, 0xDD, 0, 0, 1, 0x67, 0, 0, 1, 0x68, 0, 0, 1, 0x65]
            let enqueued = stream.withUnsafeBufferPointer { decoder.sampleBuffer(from: $0) != nil }
            #expect(!enqueued)
        }
    }
}
