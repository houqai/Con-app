import Foundation

public enum VideoCodec: Sendable { case h264, h265 }

public struct VideoStream: Sendable {
    public let codec: VideoCodec
    public private(set) var videoParameters: [UInt8]?
    public private(set) var sequenceParameters: [UInt8]?
    public private(set) var pictureParameters: [UInt8]?

    public struct Unit: Sendable {
        public var slices: [ArraySlice<UInt8>] = []
        public var isKeyframe = false
        public var parametersChanged = false
        public var carriesParameters = false
        public init() {}
        public var hasPicture: Bool { !slices.isEmpty }
        public var lengthPrefixed: [UInt8] {
            var payload = [UInt8]()
            payload.reserveCapacity(slices.reduce(0) { $0 + $1.count + 4 })
            for slice in slices { VideoStream.append(slice, lengthPrefixedTo: &payload) }
            return payload
        }
    }

    public init(codec: VideoCodec) { self.codec = codec }

    public var parameterSets: [[UInt8]]? {
        guard let sequenceParameters, let pictureParameters else { return nil }
        switch codec {
        case .h264: return [sequenceParameters, pictureParameters]
        case .h265: return videoParameters.map { [$0, sequenceParameters, pictureParameters] }
        }
    }

    public mutating func read(_ bytes: UnsafeBufferPointer<UInt8>) -> Unit {
        var unit = Unit()
        for nal in Self.units(in: bytes) {
            let type = type(of: nal[nal.startIndex])
            let kind = self.kind(type)
            if kind == .video || kind == .sequence || kind == .picture { unit.carriesParameters = true }
            switch kind {
            case .video: if videoParameters != Array(nal) { videoParameters = Array(nal); unit.parametersChanged = true }
            case .sequence: if sequenceParameters != Array(nal) { sequenceParameters = Array(nal); unit.parametersChanged = true }
            case .picture: if pictureParameters != Array(nal) { pictureParameters = Array(nal); unit.parametersChanged = true }
            case .slice:
                unit.slices.append(nal)
                if codec == .h264 ? type == 5 : (16...21).contains(type) { unit.isKeyframe = true }
            case .other: break
            }
        }
        return unit
    }

    public static func lengthPrefixed<Slice: Collection>(_ slice: Slice) -> [UInt8] where Slice.Element == UInt8 {
        var payload = [UInt8]()
        payload.reserveCapacity(slice.count + 4)
        append(slice, lengthPrefixedTo: &payload)
        return payload
    }

    private static func append<Slice: Collection>(_ slice: Slice, lengthPrefixedTo payload: inout [UInt8]) where Slice.Element == UInt8 {
        let length = UInt32(slice.count)
        payload.append(UInt8(truncatingIfNeeded: length >> 24)); payload.append(UInt8(truncatingIfNeeded: length >> 16))
        payload.append(UInt8(truncatingIfNeeded: length >> 8)); payload.append(UInt8(truncatingIfNeeded: length))
        payload.append(contentsOf: slice)
    }

    private enum Kind { case video, sequence, picture, slice, other }

    private func type(of header: UInt8) -> Int {
        switch codec {
        case .h264: return Int(header & 0x1F)
        case .h265: return Int((header >> 1) & 0x3F)
        }
    }

    private func kind(_ type: Int) -> Kind {
        switch codec {
        case .h264:
            switch type {
            case 7: return .sequence
            case 8: return .picture
            case 1, 2, 3, 4, 5: return .slice
            default: return .other
            }
        case .h265:
            switch type {
            case 32: return .video
            case 33: return .sequence
            case 34: return .picture
            case 0...31: return .slice
            default: return .other
            }
        }
    }

    public static func units(in bytes: UnsafeBufferPointer<UInt8>) -> [ArraySlice<UInt8>] {
        let array = Array(bytes)
        var starts: [Int] = []
        var i = 0
        let n = array.count
        while i + 3 <= n {
            if array[i] == 0, array[i + 1] == 0 {
                if array[i + 2] == 1 { starts.append(i + 3); i += 3; continue }
                if i + 4 <= n, array[i + 2] == 0, array[i + 3] == 1 { starts.append(i + 4); i += 4; continue }
            }
            i += 1
        }
        guard !starts.isEmpty else { return [] }
        var units: [ArraySlice<UInt8>] = []
        for (index, start) in starts.enumerated() {
            var end = index + 1 < starts.count ? startCodeBegin(array, before: starts[index + 1]) : n
            while end > start, array[end - 1] == 0 { end -= 1 }
            if start < end { units.append(array[start..<end]) }
        }
        return units
    }

    private static func startCodeBegin(_ array: [UInt8], before payloadStart: Int) -> Int {
        if payloadStart >= 4, array[payloadStart - 4] == 0, array[payloadStart - 3] == 0, array[payloadStart - 2] == 0, array[payloadStart - 1] == 1 {
            return payloadStart - 4
        }
        return payloadStart - 3
    }
}
