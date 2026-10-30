import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import SoleCore
import VideoToolbox

public final class VideoPipeline: @unchecked Sendable {
    public typealias Stats = VideoStats

    private final class Output: @unchecked Sendable {
        let layer: AVSampleBufferDisplayLayer
        let handOver = HandOver()
        private let lock = NSLock()
        private var showsImmediately = false
        private var paced: RefreshPacer?
        private var upscalingOn = false
        private var chosenMethod = Upscale.Method.fsr
        private var chosenAmount = Upscale.Amount.double
        private var upscaler: Upscaler?
        private var upscalerFailed = false
        private var upscaledWith: (Upscale.Method, Upscale.Amount)?
        private var upscaledTo = 0
        init(_ layer: AVSampleBufferDisplayLayer) { self.layer = layer }
        var pacer: RefreshPacer? {
            get { lock.withLock { paced } }
            set { lock.withLock { paced = newValue } }
        }
        var upscaling: Bool {
            get { lock.withLock { upscalingOn } }
            set { lock.withLock { upscalingOn = newValue } }
        }
        var upscaleMethod: Upscale.Method {
            get { lock.withLock { chosenMethod } }
            set { lock.withLock { chosenMethod = newValue } }
        }
        var upscaleAmount: Upscale.Amount {
            get { lock.withLock { chosenAmount } }
            set { lock.withLock { chosenAmount = newValue } }
        }
        var upscaledHeight: Int { lock.withLock { upscaledTo } }
        private func enlarged(_ buffer: CVPixelBuffer) -> CVPixelBuffer {
            let wanted: (Upscale.Method, Upscale.Amount)? = lock.withLock { upscalingOn ? (chosenMethod, chosenAmount) : nil }
            if let before = upscaledWith, !(wanted.map({ $0 == before }) ?? false) { upscaler?.release() }
            upscaledWith = wanted
            guard let chosen = wanted, let size = Upscale.size(picture: (CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer)), amount: chosen.1) else {
                lock.withLock { upscaledTo = 0 }
                return buffer
            }
            if upscaler == nil, !upscalerFailed {
                do { upscaler = try Upscaler() } catch { upscalerFailed = true }
            }
            guard let result = upscaler?.scale(buffer, width: size.width, height: size.height, method: chosen.0) else {
                lock.withLock { upscaledTo = 0 }
                return buffer
            }
            lock.withLock { upscaledTo = size.height }
            return result
        }
        var immediate: Bool {
            get { lock.withLock { showsImmediately } }
            set { lock.withLock { showsImmediately = newValue } }
        }
        private static func enqueue(_ sample: CMSampleBuffer, on layer: AVSampleBufferDisplayLayer) {
            if layer.status == .failed { layer.flush() }
            layer.enqueue(sample)
        }
        func show(_ picture: CVPixelBuffer, at time: UInt64) {
            let buffer = enlarged(picture)
            VideoPipeline.describeColours(buffer)
            var format: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format) == noErr, let format else { return }
            var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: Int64(time), timescale: 1_000_000_000), decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return }
            let pacer = pacer
            let layer = layer
            if immediate || pacer != nil {
                setSampleAttachment(sample, kCMSampleAttachmentKey_DisplayImmediately)
                if let pacer {
                    pacer.submit { Self.enqueue(sample, on: layer) }
                    return
                }
                let ahead = Int64(time) - Int64(DispatchTime.now().uptimeNanoseconds)
                handOver.submit(at: ahead < 45_000_000 ? time : 0) { Self.enqueue(sample, on: layer) }
                return
            }
            Self.enqueue(sample, on: layer)
        }
    }
    private static let colourSpace = CGColorSpace(name: CGColorSpace.itur_709)
    private static func describeColours(_ buffer: CVPixelBuffer) {
        if let colourSpace { CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, colourSpace, .shouldPropagate) }
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
    }
    private struct Generator: PictureGenerator {
        let base: any FrameGenerator
        func configure(width: Int, height: Int, limit: Int) async throws {
            try await base.configure(width: width, height: height, pixelFormat: VideoPipeline.pixelFormat, limit: limit)
        }
        func interpolate(previous: sending CVPixelBuffer, current: sending CVPixelBuffer, previousTime: UInt64, currentTime: UInt64) async throws -> GeneratedPicture<CVPixelBuffer>? {
            try await base.interpolate(previous: previous, current: current,
                                       previousTime: CMTime(value: Int64(previousTime), timescale: 1_000_000_000),
                                       currentTime: CMTime(value: Int64(currentTime), timescale: 1_000_000_000)).map { GeneratedPicture($0.buffer) }
        }
        func end() async throws { try await base.end() }
    }

    private static let pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    private let decoder: VideoDecoder
    private let layer: AVSampleBufferDisplayLayer
    private let lock = NSLock()
    private let counters = VideoCounters()
    private let queue: PictureQueue<CVPixelBuffer>
    private var lead = PresentationClock.lead
    private var session: VTDecompressionSession?
    private var keyframeFailures = 0
    private var layerDecodes = false
    private let output: Output
    private var bridge: PictureOrderBridge?
    private var cadence = PictureCadence()
    private var cadenceLog = CadenceLog(directory: Diagnostics.directory)
    private var presentationClock = PresentationClock()
    private var lastReceivedFrame: Int?
    private var signature: [UInt8] = []
    private var afterHidden = false

    public convenience init(codec: VideoDecoder.Codec, layer: AVSampleBufferDisplayLayer) {
        self.init(codec: codec, layer: layer) {
            if #available(macOS 26.0, *), FrameInterpolator.isSupported { return FrameInterpolator() }
            return nil
        }
    }

    init(codec: VideoDecoder.Codec, layer: AVSampleBufferDisplayLayer, generator: @escaping @Sendable () -> (any FrameGenerator)?) {
        decoder = VideoDecoder(codec: codec)
        bridge = codec == .h265 ? PictureOrderBridge() : nil
        self.layer = layer
        var timebase: CMTimebase?
        if CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase) == noErr, let timebase {
            CMTimebaseSetTime(timebase, time: CMClockGetTime(CMClockGetHostTimeClock()))
            CMTimebaseSetRate(timebase, rate: 1)
            layer.controlTimebase = timebase
        }
        let output = Output(layer)
        self.output = output
        queue = PictureQueue(counters: counters,
                             generator: { generator().map { Generator(base: $0) } },
                             size: { (CVPixelBufferGetWidth($0), CVPixelBufferGetHeight($0)) },
                             show: { output.show($0, at: $1) })
    }

    public var frameGeneration: Bool {
        get { queue.frameGeneration }
        set { queue.frameGeneration = newValue }
    }
    public var presentationLead: Double {
        get { lock.withLock { lead } }
        set {
            lock.withLock { lead = max(0, newValue) }
            output.immediate = newValue < PresentationClock.lead
            counters.update { $0.shownAtHandOver = newValue < PresentationClock.lead }
        }
    }
    public var refreshPacer: RefreshPacer? {
        get { output.pacer }
        set { output.pacer = newValue }
    }
    public var displayRate: Double {
        get { queue.displayRate }
        set { queue.displayRate = newValue }
    }
    public var generationHeight: Int {
        get { queue.generationHeight }
        set { queue.generationHeight = newValue }
    }
    public static let defaultGenerationHeight = GenerationState.defaultHeight
    public static var generationHeights: [Int] {
        if #available(macOS 26.0, *), FrameInterpolator.isSupported { return FrameInterpolator.heights }
        return [defaultGenerationHeight]
    }
    public static var generationSupported: Bool {
        if #available(macOS 26.0, *) { return FrameInterpolator.isSupported }
        return false
    }
    public func snapshot() -> Stats {
        var stats = counters.snapshot
        stats.upscaledHeight = output.upscaledHeight
        return stats
    }
    public var upscaling: Bool {
        get { output.upscaling }
        set { output.upscaling = newValue }
    }
    public var upscaleMethod: Upscale.Method {
        get { output.upscaleMethod }
        set { output.upscaleMethod = newValue }
    }
    public var upscaleAmount: Upscale.Amount {
        get { output.upscaleAmount }
        set { output.upscaleAmount = newValue }
    }

    public var onFailure: (@Sendable () -> Void)?

    private final class Decoded { var status: OSStatus = kVTVideoDecoderBadDataErr; var image: CVImageBuffer? }

    @discardableResult
    public func submit(_ bytes: UnsafeBufferPointer<UInt8>, frame: Int? = nil, display: Bool = true) -> Bool {
        var missing = 0
        if let frame, let previous = lastReceivedFrame {
            let delta = (frame - previous) & 0xffff
            if delta > 0 && delta < 32768 { missing = delta - 1 }
        }
        lastReceivedFrame = frame
        counters.update { $0.receivedFrames += 1; $0.bytes += bytes.count; $0.missingFrames += missing }
        guard let sample = decoder.sampleBuffer(from: bytes), let format = CMSampleBufferGetFormatDescription(sample) else {
            guard decoder.lastUnitHadPicture else {
                if let format = decoder.currentFormat { prepareSession(for: format) }
                return true
            }
            return failed()
        }
        if decoder.lastUnitWasKeyframe { counters.update { $0.keyframes += 1 } }
        prepareSession(for: format)
        guard let session else {
            if !display { setSampleAttachment(sample, kCMSampleAttachmentKey_DoNotDisplay) }
            if layer.requiresFlushToResumeDecoding { layer.flush() }
            layer.enqueue(sample)
            let wanted = queue.frameGeneration
            counters.update { if display { $0.shownFrames += 1 } else { $0.hiddenFrames += 1 }; if wanted { $0.generation = .unavailable } }
            return true
        }
        var bridgeSlices: [[UInt8]] = []
        switch bridge?.examine(decoder.lastUnitSlices, sps: decoder.sequenceParameters, pps: decoder.pictureParameters, frame: frame) {
        case .missingReference: return failed()
        case .decode(let copies): bridgeSlices = copies
        case nil: break
        }
        let started = DispatchTime.now().uptimeNanoseconds
        let lead = presentationLead
        if lead > 0, presentationClock.lead != lead { presentationClock.lead = lead }
        var result = (status: noErr, image: nil as CVImageBuffer?)
        for slice in bridgeSlices where result.status == noErr {
            result = decoder.sampleBuffer(slice: slice).map { Self.decode($0, in: session) } ?? (kVTVideoDecoderBadDataErr, nil)
        }
        if result.status == noErr { result = Self.decode(sample, in: session) }
        guard result.status == noErr, let image = result.image else {
            bridge?.finish(decoded: false)
            if decoder.lastUnitWasKeyframe { keyframeFailures += 1 }
            if result.status == kVTInvalidSessionErr || decoder.lastUnitWasKeyframe {
                VTDecompressionSessionInvalidate(session); self.session = nil
                if keyframeFailures >= 2 { layerDecodes = true }
            }
            return failed()
        }
        bridge?.finish(decoded: true)
        keyframeFailures = 0
        let arrival = DispatchTime.now().uptimeNanoseconds
        guard display else {
            afterHidden = true
            if lead > 0 { _ = presentationClock.timestamp(arrival: arrival, frame: frame, isNew: false) }
            counters.update { $0.hiddenFrames += 1; $0.decodeMs = Double(arrival - started) / 1_000_000 }
            return true
        }
        let discontinuity = missing > 0 || afterHidden
        afterHidden = false
        let current = PictureCadence.signature(of: image)
        let change = PictureCadence.change(from: signature, to: current)
        if discontinuity { cadence = PictureCadence() }
        let isNew = discontinuity || cadence.isNew(change: change)
        cadenceLog.add(change: change, new: isNew)
        signature = current
        let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
        let bridged = !bridgeSlices.isEmpty
        counters.update {
            $0.decodeMs = Double(arrival - started) / 1_000_000
            $0.width = width; $0.height = height
            $0.lastChange = change
            if isNew { $0.newFrames += 1 }
            if bridged { $0.bridgedLosses += 1 }
        }
        let presentation = lead > 0 ? presentationClock.timestamp(arrival: arrival, frame: frame, isNew: isNew) : arrival
        let ahead = presentation > arrival ? Double(presentation - arrival) / 1_000_000 : 0
        counters.update { $0.presentationMs += (ahead - $0.presentationMs) / ($0.receivedFrames < 16 ? 1 : 16) }
        queue.submit(image, time: presentation, isNew: isNew, discontinuity: discontinuity, decodedAt: arrival)
        return true
    }

    private func prepareSession(for format: CMFormatDescription) {
        if let session, !VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: format) {
            VTDecompressionSessionInvalidate(session)
            self.session = nil
            bridge?.reset()
        }
        guard session == nil, !layerDecodes else { return }
        session = Self.makeSession(format)
        let hardware = session.flatMap { made -> Bool? in
            var value: CFTypeRef?
            let status = withUnsafeMutablePointer(to: &value) { VTSessionCopyProperty(made, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, allocator: kCFAllocatorDefault, valueOut: $0) }
            guard status == noErr else { return nil }
            return value as? Bool
        }
        let codec = CMFormatDescriptionGetMediaSubType(format)
        counters.update { $0.codec = codec; $0.hardwareDecoder = hardware }
    }

    private static func decode(_ sample: CMSampleBuffer, in session: VTDecompressionSession) -> (status: OSStatus, image: CVImageBuffer?) {
        let output = Decoded()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            output.status = status; output.image = image
        }
        return (status != noErr ? status : output.status, output.image)
    }

    private func failed() -> Bool {
        counters.update { $0.decodeFailures += 1 }
        onFailure?()
        return false
    }

    public func invalidate() {
        queue.invalidate()
        output.handOver.stop()
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
    }
    deinit { invalidate() }

    private static func makeSession(_ format: CMFormatDescription) -> VTDecompressionSession? {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil,
                                                  imageBufferAttributes: attributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &session)
        guard status == noErr, let session else { return nil }
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        return session
    }

    static var failuresToGiveUp: Int { PictureQueue<CVPixelBuffer>.failuresToGiveUp }
}
