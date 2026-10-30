import CoreMedia
import Foundation
import SoleCore

public final class VideoDecoder {
    public typealias Codec = VideoCodec

    private var stream: VideoStream
    public private(set) var currentFormat: CMFormatDescription?
    private var lastUnit = VideoStream.Unit()

    public init(codec: Codec) { stream = VideoStream(codec: codec) }

    public var lastUnitHadPicture: Bool { lastUnit.hasPicture }
    public var lastUnitWasKeyframe: Bool { lastUnit.isKeyframe }
    public var lastUnitSlices: [ArraySlice<UInt8>] { lastUnit.slices }
    public var sequenceParameters: [UInt8]? { stream.sequenceParameters }
    public var pictureParameters: [UInt8]? { stream.pictureParameters }

    public func sampleBuffer(slice: [UInt8]) -> CMSampleBuffer? {
        guard let currentFormat else { return nil }
        return Self.makeSampleBuffer(VideoStream.lengthPrefixed(slice), format: currentFormat)
    }

    public func sampleBuffer(from bytes: UnsafeBufferPointer<UInt8>) -> CMSampleBuffer? {
        lastUnit = stream.read(bytes)
        if lastUnit.parametersChanged, let sets = stream.parameterSets { currentFormat = Self.format(stream.codec, parameterSets: sets) }
        guard lastUnit.hasPicture, let format = currentFormat else { return nil }
        return Self.makeSampleBuffer(lastUnit.lengthPrefixed, format: format)
    }

    private static func format(_ codec: Codec, parameterSets sets: [[UInt8]]) -> CMFormatDescription? {
        let copies = sets.map { set -> UnsafeMutablePointer<UInt8> in
            let copy = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, set.count))
            copy.initialize(from: set, count: set.count)
            return copy
        }
        defer { copies.forEach { $0.deallocate() } }
        let pointers = copies.map { UnsafePointer($0) }, sizes = sets.map(\.count)
        var description: CMFormatDescription?
        let status: OSStatus
        switch codec {
        case .h264:
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers, parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
        case .h265:
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers, parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description)
        }
        return status == noErr ? description : nil
    }

    static func makeSampleBuffer(_ payload: [UInt8], format: CMFormatDescription) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: payload.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: payload.count, flags: 0, blockBufferOut: &blockBuffer) == kCMBlockBufferNoErr,
              let copied = blockBuffer else { return nil }
        let status = payload.withUnsafeBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return kCMBlockBufferBadLengthParameterErr }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: copied, offsetIntoDestination: 0, dataLength: bytes.count)
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = payload.count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: copied, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sampleBuffer) == noErr, let sampleBuffer else { return nil }

        setSampleAttachment(sampleBuffer, kCMSampleAttachmentKey_DisplayImmediately)
        return sampleBuffer
    }
}

func setSampleAttachment(_ sample: CMSampleBuffer, _ key: CFString) {
    guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [CFMutableDictionary], let first = attachments.first else { return }
    CFDictionarySetValue(first, Unmanaged.passUnretained(key).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
}
