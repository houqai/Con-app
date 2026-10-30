import CConAndroid
import Foundation
import SoleCore
import SoleEngine
import SoleLogic

public final class AndroidMedia: StreamMedia, @unchecked Sendable {
    public var requestKeyframe: (@Sendable () -> Void)?
    private let hevc: Bool
    private let lock = NSLock()
    private var stream: VideoStream
    private let figures = VideoCounters()
    private var active = true
    private var open = false
    private var gate: LossGate
    private var clock = PresentationClock()
    private var lead = PresentationClock.lead
    private var keyframeAsked = 0.0
    private var audioBuffers = 0, loudBuffers = 0
    static let silence: Int32 = 64
    private static let hvc1: UInt32 = 0x68766331
    private static let avc1: UInt32 = 0x61766331
    private static let figuresLock = NSLock()
    nonisolated(unsafe) private static var heardBuffers = 0, loudestSample: Int32 = 0
    static var heard: Int { figuresLock.withLock { heardBuffers } }
    static var peak: Int { figuresLock.withLock { Int(loudestSample) } }
    private static func measure(_ loudest: Int32) {
        figuresLock.withLock {
            if loudest > silence { heardBuffers += 1 }
            loudestSample = max(loudestSample, loudest)
        }
    }
    static func resetFigures() {
        figuresLock.withLock {
            heardBuffers = 0
            loudestSample = 0
        }
    }

    public init(hevc: Bool) {
        self.hevc = hevc
        Self.resetFigures()
        stream = VideoStream(codec: hevc ? .h265 : .h264)
        gate = LossGate()
    }

    public func video(_ buffer: UnsafeBufferPointer<UInt8>, frame: Int32, display: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard active, let bytes = buffer.baseAddress else { return true }
        let unit = stream.read(buffer)
        figures.update { $0.receivedFrames += 1; $0.bytes += buffer.count; if unit.isKeyframe { $0.keyframes += 1 } }
        if !open {
            open = con_video_open(hevc ? 1 : 0) == 0
            if open { gate.restart(); clock = PresentationClock(lead: lead); keyframeAsked = 0 }
        }
        if !open {
            if !unit.hasPicture { return true }
            return con_video_ready() == 0 ? false : lost()
        }
        let counter = frame >= 0 ? Int(frame) : nil
        let decision = gate.take(unit, of: stream, frame: counter)
        figures.update { $0.missingFrames += gate.missing }
        guard decision == .decode else { return lost() }
        var delay: Int64 = 0
        if unit.hasPicture, lead > 0 {
            let arrival = DispatchTime.now().uptimeNanoseconds
            if gate.missing > 0 || clock.lead != lead { clock = PresentationClock(lead: lead) }
            let shown = clock.timestamp(arrival: arrival, frame: counter, isNew: display)
            delay = shown > arrival ? Int64((shown - arrival) / 1000) : 0
            if display { figures.update { $0.presentationMs += (Double(delay) / 1000 - $0.presentationMs) / ($0.receivedFrames < 16 ? 1 : 16) } }
        }
        if unit.hasPicture, !display { delay = -1 }
        let taken = gate.parametersFirst.isEmpty
            ? con_video_submit(bytes, Int32(buffer.count), unit.hasPicture ? 0 : 1, delay)
            : (gate.parametersFirst.flatMap { [0, 0, 0, 1] + $0 } + buffer).withUnsafeBufferPointer { con_video_submit($0.baseAddress, Int32($0.count), 0, delay) }
        if taken < 0 { open = false }
        gate.decoded(taken > 0)
        if taken > 0, unit.hasPicture, !display { figures.update { $0.hiddenFrames += 1 } }
        guard taken > 0 || !unit.hasPicture else { return lost() }
        return true
    }

    private func lost() -> Bool {
        figures.update { $0.decodeFailures += 1 }
        let now = ProcessInfo.processInfo.systemUptime
        if now - keyframeAsked > 2 { keyframeAsked = now; requestKeyframe?() }
        return false
    }

    public func audio(_ samples: UnsafeBufferPointer<Int16>, channels: Int, rate: Int) {
        lock.lock(); defer { lock.unlock() }
        guard active, channels > 0, let base = samples.baseAddress else { return }
        var loudest: Int32 = 0
        for sample in samples { loudest = max(loudest, abs(Int32(sample))) }
        Self.measure(loudest)
        guard con_audio_open(Int32(channels), Int32(rate)) == 0 else { return }
        audioBuffers += 1
        if loudest > Self.silence { loudBuffers += 1 }
        con_audio_write(base, Int32(samples.count / channels))
    }

    public func counters() -> StreamMeter.Reading {
        var reading = StreamMeter.Reading()
        var pictures: Int32 = 0, width: Int32 = 0, height: Int32 = 0, written: Int32 = 0, refused: Int32 = 0
        con_video_counts(&pictures, &width, &height)
        con_audio_counts(&written, &refused)
        let hevc = hevc
        reading.video = figures.update {
            $0.shownFrames = Int(pictures); $0.newFrames = Int(pictures)
            $0.decodeMs = Double(con_video_decode_us()) / 1000
            $0.width = Int(width); $0.height = Int(height); $0.hardwareDecoder = true
            $0.codec = hevc ? Self.hvc1 : Self.avc1
            return $0
        }
        let (buffers, loud) = lock.withLock { (audioBuffers, loudBuffers) }
        reading.audioReceived = buffers
        reading.audioNonSilent = loud
        reading.audioPlayed = buffers - Int(refused)
        reading.audioErrors = Int(refused)
        reading.askedHEVC = hevc
        return reading
    }

    public func show(_ picture: StreamPicture) {
        lock.lock(); lead = Double(Smoothness.lead(picture.presentationLeadMs)) * 1_000_000; lock.unlock()
        con_video_pacing(picture.presentationLeadMs == Smoothness.byRefresh ? 1 : 0)
    }

    public func close() {
        lock.lock(); active = false; lock.unlock()
        con_video_close()
        con_audio_close()
    }
}

@MainActor final class AndroidStreamDevice: StreamDevice {
    func openMedia(hevc: Bool) -> StreamMedia { AndroidMedia(hevc: hevc) }
    func clearPicture() {}
    func stopSound() { con_audio_close() }
    var generationSupported: Bool { false }
    var displayHz: Int { 0 }
    var fillsWindow = false
    func toggleFullScreen() {}
    var leavesFullScreen: Bool { false }
    func keepAwake(_ on: Bool) { con_java_keep_awake(on ? 1 : 0) }

    private var deliver: ((ControllerState?) -> Void)?
    func startInput(deliver: @escaping (ControllerState?) -> Void) {
        self.deliver = deliver
        deliver(ControllerState())
    }
    func stopInput() { deliver = nil }
    func take(_ reading: PadReading?) {
        guard let deliver else { return }
        guard let reading else { deliver(nil); return }
        var state = ControllerState()
        state.merge(PadReading(), pad: reading)
        deliver(state)
    }
    func resetMotion() {}
    func releasePointer() {}

    func beginFeedback() {}
    func feedback(_ report: DualSenseReport) {}
    func haptics(_ pcm: Data) {}
    func effectIntensity(trigger: Bool, value: UInt32) {}
    func silenceFeedback() {}
    var playedHaptics: Int { 0 }

    func loadConsoles() -> [RegisteredConsole] {
        guard let stored = try? AndroidCredentials.read("consoles") else { return [] }
        return (try? JSONDecoder().decode([RegisteredConsole].self, from: stored)) ?? []
    }
    func saveConsoles(_ consoles: [RegisteredConsole]) -> Bool {
        guard let data = try? JSONEncoder().encode(consoles) else { return false }
        return (try? AndroidCredentials.write(data, "consoles")) != nil
    }
}
