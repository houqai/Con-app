import Testing
@testable import SoleCore

@Suite struct VideoStreamTests {
    private func split(_ bytes: [UInt8]) -> [[UInt8]] {
        bytes.withUnsafeBufferPointer { VideoStream.units(in: $0).map(Array.init) }
    }
    private func read(_ stream: inout VideoStream, _ bytes: [UInt8]) -> VideoStream.Unit {
        bytes.withUnsafeBufferPointer { stream.read($0) }
    }

    @Test func splitsFourByteStartCodes() {
        let units = split([0,0,0,1, 0x67, 0xAA, 0xBB, 0,0,0,1, 0x68, 0xCC])
        #expect(units == [[0x67, 0xAA, 0xBB], [0x68, 0xCC]])
    }
    @Test func splitsThreeByteStartCodes() {
        #expect(split([0,0,1, 0x41, 0x01, 0,0,1, 0x41, 0x02]) == [[0x41, 0x01], [0x41, 0x02]])
    }
    @Test func ignoresBytesBeforeFirstStartCode() {
        #expect(split([0xFF, 0xFF, 0,0,0,1, 0x65, 0x10]) == [[0x65, 0x10]])
    }
    @Test func dropsPaddingAfterUnits() {
        let stream: [UInt8] = [0,0,0,1, 0x40, 0x01, 0x0C, 0,0,0, 0,0,0,1, 0x42, 0x01, 0x80, 0,0,0,0,0,0,0,0]
        #expect(split(stream) == [[0x40, 0x01, 0x0C], [0x42, 0x01, 0x80]])
    }
    @Test func emptyWithoutStartCode() {
        #expect(split([0x01, 0x02, 0x03]).isEmpty)
        #expect(split([]).isEmpty)
    }

    @Test func h264KeepsItsParameterSetsAndTellsAKeyframeFromTheRest() {
        var stream = VideoStream(codec: .h264)
        #expect(stream.parameterSets == nil)
        let first = read(&stream, [0,0,0,1, 0x67, 0x64, 0x1F, 0,0,0,1, 0x68, 0xEE, 0,0,1, 0x65, 0x88, 0x84])
        #expect(first.parametersChanged)
        #expect(first.hasPicture)
        #expect(first.isKeyframe)
        #expect(first.slices.map(Array.init) == [[0x65, 0x88, 0x84]])
        #expect(stream.parameterSets == [[0x67, 0x64, 0x1F], [0x68, 0xEE]])
        #expect(stream.videoParameters == nil)
        let second = read(&stream, [0,0,0,1, 0x41, 0x9A])
        #expect(!second.parametersChanged)
        #expect(second.hasPicture)
        #expect(!second.isKeyframe)
        let same = read(&stream, [0,0,0,1, 0x67, 0x64, 0x1F, 0,0,0,1, 0x68, 0xEE])
        #expect(!same.parametersChanged)
        #expect(!same.hasPicture)
        let other = read(&stream, [0,0,0,1, 0x67, 0x64, 0x28])
        #expect(other.parametersChanged)
        #expect(stream.sequenceParameters == [0x67, 0x64, 0x28])
    }

    @Test func h265NeedsItsThreeParameterSetsInTheirOrder() {
        var stream = VideoStream(codec: .h265)
        _ = read(&stream, [0,0,0,1, 0x42, 0x01, 0xBB, 0,0,0,1, 0x44, 0x01, 0xCC])
        #expect(stream.parameterSets == nil)
        let unit = read(&stream, [0,0,0,1, 0x40, 0x01, 0xAA, 0,0,0,1, 0x26, 0x01, 0xDD])
        #expect(unit.parametersChanged)
        #expect(stream.parameterSets == [[0x40, 0x01, 0xAA], [0x42, 0x01, 0xBB], [0x44, 0x01, 0xCC]])
        #expect(unit.isKeyframe)
        let trailing = read(&stream, [0,0,0,1, 0x02, 0x01, 0xD0])
        #expect(trailing.hasPicture)
        #expect(!trailing.isKeyframe)
        let information = read(&stream, [0,0,0,1, 0x4E, 0x01, 0x05])
        #expect(!information.hasPicture)
        for type in UInt8(0)...31 {
            let picture = read(&stream, [0,0,1, type << 1, 0x01, 0x80])
            #expect(picture.isKeyframe == (16...21).contains(type), "type \(type)")
        }
    }

    @Test func slicesGoToTheDecoderBehindTheirLengths() {
        var stream = VideoStream(codec: .h264)
        let unit = read(&stream, [0,0,1, 0x41, 0x01, 0,0,1, 0x41, 0x02, 0x03])
        #expect(unit.lengthPrefixed == [0,0,0,2, 0x41, 0x01, 0,0,0,3, 0x41, 0x02, 0x03])
        #expect(VideoStream.lengthPrefixed([UInt8](repeating: 7, count: 258)).prefix(5) == [0, 0, 1, 2, 7])
        #expect(VideoStream.lengthPrefixed(unit.slices[1]) == [0,0,0,3, 0x41, 0x02, 0x03])
    }
}
