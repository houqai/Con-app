import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

public struct GeneratedFrame: @unchecked Sendable {
    public let buffer: CVPixelBuffer
    public let timestamp: CMTime
}

protocol FrameGenerator: Sendable {
    func configure(width: Int, height: Int, pixelFormat: OSType, limit: Int) async throws
    func interpolate(previous: sending CVPixelBuffer, current: sending CVPixelBuffer, previousTime: CMTime, currentTime: CMTime) async throws -> GeneratedFrame?
    func end() async throws
}

@available(macOS 26.0, *)
public actor FrameInterpolator: FrameGenerator {
    public enum Failure: Error { case unsupported, invalidConfiguration, incompatibleFrame, busy, allocation(OSStatus), processing }
    public static var systemLimit: (side: Int, pixels: Int) {
        if #available(macOS 27.0, *), let side = VTLowLatencyFrameInterpolationConfiguration.maximumDimension(forSpatialScaleFactor: 1),
           let pixels = VTLowLatencyFrameInterpolationConfiguration.maximumPixelCount(forSpatialScaleFactor: 1), side > 0, pixels > 0 { return (side, pixels) }
        return (1920, 1920 * 1080)
    }
    public static var heights: [Int] {
        let system = systemLimit
        return [720, 1080, 1440, 2160].filter { $0 == 720 || ($0 * 16 / 9 <= system.side && $0 * 16 / 9 * $0 <= system.pixels) }
    }
    private var processor: VTFrameProcessor?
    private var pool: CVPixelBufferPool?
    private var transfer: VTPixelTransferSession?
    private var copies: CVPixelBufferPool?
    private var reduced: (of: CVPixelBuffer, copy: CVPixelBuffer)?
    private var width = 0
    private var height = 0
    private var format: OSType = 0
    private var processing = false
    private var ready = false

    public init() {}
    public static var isSupported: Bool { VTLowLatencyFrameInterpolationConfiguration.isSupported }

    public static func workingSize(width: Int, height: Int, limit: Int = VideoPipeline.defaultGenerationHeight, system: (side: Int, pixels: Int) = systemLimit) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (width, height) }
        let scale = min(Double(limit) * 16 / 9 / Double(width), Double(limit) / Double(height),
                        Double(system.side) / Double(max(width, height)), (Double(system.pixels) / Double(width * height)).squareRoot())
        guard scale < 1 else { return (width, height) }
        func even(_ value: Double) -> Int { max(2, Int((value / 2).rounded()) * 2) }
        var size = (width: even(Double(width) * scale), height: even(Double(height) * scale))
        while size.width * size.height > system.pixels, size.height > 2 { size.height -= 2 }
        return size
    }

    public func configure(width: Int, height: Int, pixelFormat: OSType, limit: Int = VideoPipeline.defaultGenerationHeight) throws {
        guard !processing else { throw Failure.busy }
        guard Self.isSupported else { throw Failure.unsupported }
        let size = Self.workingSize(width: width, height: height, limit: limit)
        guard width > 0, height > 0,
              let configuration = VTLowLatencyFrameInterpolationConfiguration(frameWidth: size.width, frameHeight: size.height, numberOfInterpolatedFrames: 1),
              configuration.supportedPixelFormats.contains(pixelFormat) else { throw Failure.invalidConfiguration }
        reset()
        let created = try Self.pool(configuration.destinationPixelBufferAttributes, size: size, pixelFormat: pixelFormat)
        var scaler: VTPixelTransferSession?
        var scaled: CVPixelBufferPool?
        if size != (width, height) {
            scaled = try Self.pool(configuration.sourcePixelBufferAttributes, size: size, pixelFormat: pixelFormat)
            let status = VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &scaler)
            guard status == noErr, let scaler else { throw Failure.allocation(status) }
            VTSessionSetProperty(scaler, key: kVTPixelTransferPropertyKey_RealTime, value: kCFBooleanTrue)
        }
        let createdProcessor = VTFrameProcessor()
        try createdProcessor.startSession(configuration: configuration)
        processor = createdProcessor
        self.width = width; self.height = height; format = pixelFormat; pool = created; transfer = scaler; copies = scaled; ready = true
    }

    private static func pool(_ base: [String: Any], size: (width: Int, height: Int), pixelFormat: OSType) throws -> CVPixelBufferPool {
        var attributes = base
        attributes[kCVPixelBufferWidthKey as String] = size.width
        attributes[kCVPixelBufferHeightKey as String] = size.height
        attributes[kCVPixelBufferPixelFormatTypeKey as String] = pixelFormat
        attributes[kCVPixelBufferIOSurfacePropertiesKey as String] = [:] as [String: Any]
        attributes[kCVPixelBufferMetalCompatibilityKey as String] = true
        var created: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &created)
        guard status == kCVReturnSuccess, let created else { throw Failure.allocation(status) }
        return created
    }

    private func reduce(_ picture: CVPixelBuffer) throws -> CVPixelBuffer {
        guard let transfer, let copies else { return picture }
        var copy: CVPixelBuffer?
        let allocation = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, copies, &copy)
        guard allocation == kCVReturnSuccess, let copy else { throw Failure.allocation(allocation) }
        guard VTPixelTransferSessionTransferImage(transfer, from: picture, to: copy) == noErr else { throw Failure.processing }
        return copy
    }

    public func interpolate(previous: sending CVPixelBuffer, current: sending CVPixelBuffer, previousTime: CMTime, currentTime: CMTime) async throws -> GeneratedFrame? {
        guard ready, let pool, let processor else { throw Failure.invalidConfiguration }
        guard !processing else { throw Failure.busy }
        guard [previous, current].allSatisfy({ CVPixelBufferGetWidth($0) == width && CVPixelBufferGetHeight($0) == height && CVPixelBufferGetPixelFormatType($0) == format }) else { throw Failure.incompatibleFrame }
        let delta = CMTimeGetSeconds(CMTimeSubtract(currentTime, previousTime))
        guard previousTime.isNumeric, currentTime.isNumeric, delta.isFinite, delta > 0, delta <= 0.1 else { return nil }
        let midpoint = CMTimeAdd(previousTime, CMTime(seconds: delta / 2, preferredTimescale: 1_000_000_000))
        let before = try reduced.flatMap { $0.of === previous ? $0.copy : nil } ?? reduce(previous)
        let now = try reduce(current)
        reduced = transfer == nil ? nil : (current, now)
        var output: CVPixelBuffer?
        let allocation = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, [kCVPixelBufferPoolAllocationThresholdKey: 8] as CFDictionary, &output)
        if allocation == kCVReturnWouldExceedAllocationThreshold { return nil }
        guard allocation == kCVReturnSuccess, let output else { throw Failure.allocation(allocation) }
        CVBufferPropagateAttachments(now, output)
        guard let source = VTFrameProcessorFrame(buffer: now, presentationTimeStamp: currentTime),
              let reference = VTFrameProcessorFrame(buffer: before, presentationTimeStamp: previousTime),
              let destination = VTFrameProcessorFrame(buffer: output, presentationTimeStamp: midpoint),
              let parameters = VTLowLatencyFrameInterpolationParameters(sourceFrame: source, previousFrame: reference, interpolationPhase: [0.5], destinationFrames: [destination]) else { throw Failure.incompatibleFrame }
        processing = true
        defer { processing = false }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            processor.process(parameters: parameters) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        try Task.checkCancellation()
        return GeneratedFrame(buffer: output, timestamp: midpoint)
    }

    public func end() throws {
        guard !processing else { throw Failure.busy }
        reset()
    }

    private func reset() {
        processor?.endSession(); processor = nil; ready = false; pool = nil; transfer = nil; copies = nil; reduced = nil
    }
    deinit { processor?.endSession() }
}
