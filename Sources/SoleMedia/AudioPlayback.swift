import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import SoleCore

public final class AudioPlayback: @unchecked Sendable {
    private let queue: DispatchQueue
    private let output: AudioPlaybackOutput
    private var observer: NSObjectProtocol?
    private var format: AVAudioFormat?
    public typealias Stats = SoundQueue.Stats
    private var sound = SoundQueue() {
        didSet { let stats = sound.stats; statsLock.withLock { published = stats } }
    }
    private let statsLock = NSLock()
    private var published = SoundQueue.Stats()
    private let now: () -> TimeInterval
    public convenience init() {
        self.init(output: EngineAudioOutput(), queue: DispatchQueue(label: "app.sole.audio", qos: .userInteractive))
    }
    init(output: AudioPlaybackOutput, queue: DispatchQueue, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
        self.output = output
        self.queue = queue
        if let source = output.notificationSource {
            observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: source, queue: nil) { [weak self] _ in
                self?.queue.async { [weak self] in self?.startOver() }
            }
        }
        output.onRouteChange = { [weak self] in
            self?.queue.async { [weak self] in self?.startOver() }
        }
    }
    private func startOver() {
        guard sound.startOver(now: now()) else { return }
        output.stop()
        format = nil
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    public func submit(_ pcm: UnsafeBufferPointer<Int16>, channels: Int, rate: Int) {
        guard SoundQueue.accepts(samples: pcm.count, channels: channels, rate: rate) else { return }
        let samples = Array(pcm)
        queue.async { [self] in
            if sound.arrived(audible: SoundQueue.isAudible(samples), channels: channels, rate: rate, outputAlive: output.isRunning && output.isPlaying, now: now()) {
                output.stop()
                guard let next = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: AVAudioChannelCount(channels)) else { return }
                do {
                    output.configure(next)
                    try output.start()
                    format = next
                    sound.started(channels: channels, rate: rate)
                } catch {
                    format = nil
                    sound.startFailed()
                    NSLog("Con audio: playback start failed: %@", error.localizedDescription)
                    return
                }
            }
            guard sound.hasRoom, let format,
                  let buffer = Self.buffer(samples, channels: channels, format: format) else { return }
            let mark = sound.schedule(now: now())
            output.schedule(buffer) { [weak self] in
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    self.sound.played(mark: mark, now: self.now())
                }
            }
        }
    }
    public func snapshot() -> Stats { statsLock.withLock { published } }
    public func stop() { queue.async { [self] in sound.stop(now: now()); output.stop(); format = nil } }

    static func buffer(_ samples: [Int16], channels: Int, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard channels > 0, samples.count % channels == 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count / channels)),
              let output = buffer.floatChannelData else { return nil }
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<channels {
            for frame in 0..<Int(buffer.frameLength) {
                output[channel][frame] = Float(samples[frame * channels + channel]) / 32768
            }
        }
        return buffer
    }
}

protocol AudioPlaybackOutput: AnyObject {
    var notificationSource: AnyObject? { get }
    var onRouteChange: (() -> Void)? { get set }
    var isRunning: Bool { get }
    var isPlaying: Bool { get }
    func configure(_ format: AVAudioFormat)
    func start() throws
    func stop()
    func schedule(_ buffer: AVAudioPCMBuffer, completion: @escaping () -> Void)
}

private final class EngineAudioOutput: AudioPlaybackOutput {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    var onRouteChange: (() -> Void)?
    private var routeListener: AudioObjectPropertyListenerBlock?
    private static var systemOutput = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    init() {
        engine.attach(player)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onRouteChange?() }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.systemOutput, nil, listener) == noErr { routeListener = listener }
    }
    deinit {
        if let routeListener { AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.systemOutput, nil, routeListener) }
    }
    var notificationSource: AnyObject? { engine }
    var isRunning: Bool { engine.isRunning }
    var isPlaying: Bool { player.isPlaying }
    func configure(_ format: AVAudioFormat) {
        var address = Self.systemOutput
        var device: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
           device != 0, let unit = engine.outputNode.audioUnit {
            let result = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, size)
            if result != noErr { NSLog("Con audio: output binding failed (%d)", result) }
        }
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        let deviceFormat = engine.outputNode.inputFormat(forBus: 0)
        if deviceFormat.sampleRate > 0, deviceFormat.channelCount > 0 {
            engine.disconnectNodeOutput(engine.mainMixerNode)
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: deviceFormat)
        }
    }
    func start() throws {
        try engine.start()
        if let exception = SoleCatchException({ [player] in player.play() }) {
            engine.stop()
            throw NSError(domain: "app.sole.audio", code: 1, userInfo: [NSLocalizedDescriptionKey: exception.reason ?? exception.name.rawValue])
        }
    }
    func stop() { player.stop(); engine.stop() }
    func schedule(_ buffer: AVAudioPCMBuffer, completion: @escaping () -> Void) {
        player.scheduleBuffer(buffer, completionCallbackType: .dataRendered) { _ in completion() }
    }
}
