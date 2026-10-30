import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import SoleCore

public final class DualSenseHaptics {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private var nextAttempt = Date.distantPast
    private var device: AudioDeviceID = 0
    private var volumeBefore: (volume: Float32?, muted: UInt32?)?
    private let lock = NSLock()
    private var pending = 0
    private var played = 0
    public var playedBuffers: Int { lock.withLock { played } }
    private var generation = UUID()
    public init() {}
    public func stop() {
        lock.withLock { generation = UUID(); pending = 0; played = 0 }
        player?.stop(); engine?.stop(); player = nil; engine = nil; format = nil
        if let volumeBefore {
            if let volume = volumeBefore.volume { Self.set(kAudioDevicePropertyVolumeScalar, of: device, to: volume) }
            if let muted = volumeBefore.muted { Self.set(kAudioDevicePropertyMute, of: device, to: muted) }
            self.volumeBefore = nil
        }
    }
    private func configure() -> Bool {
        if engine?.isRunning == true { return true }
        guard Date() >= nextAttempt else { return false }
        nextAttempt = Date().addingTimeInterval(0.25)
        if let engine, let player {
            lock.withLock { generation = UUID(); pending = 0 }
            player.stop()
            do { try engine.start(); try Self.play(player); return true }
            catch {
                NSLog("Con DualSense: USB haptics restart failed: %@", error.localizedDescription)
                stop()
                return false
            }
        }
        stop()
        guard let device = Self.usbDevice() else { return false }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, interleaved: false, channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4)!)
        let engine = AVAudioEngine()
        guard let unit = engine.outputNode.audioUnit else { return false }
        var deviceID = device
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else { return false }
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)
        do { try engine.start(); try Self.play(player) }
        catch { NSLog("Con DualSense: USB haptics start failed: %@", error.localizedDescription); engine.stop(); return false }
        self.engine = engine; self.player = player; self.format = format
        self.device = device
        let volume: Float32? = Self.get(kAudioDevicePropertyVolumeScalar, of: device), muted: UInt32? = Self.get(kAudioDevicePropertyMute, of: device)
        volumeBefore = (volume, muted)
        if let volume, volume < 1 { Self.set(kAudioDevicePropertyVolumeScalar, of: device, to: Float32(1)) }
        if muted == 1 { Self.set(kAudioDevicePropertyMute, of: device, to: UInt32(0)) }
        return true
    }
    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }
    private static func get<Value>(_ selector: AudioObjectPropertySelector, of device: AudioDeviceID) -> Value? {
        var address = address(selector)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        let value = UnsafeMutablePointer<Value>.allocate(capacity: 1); defer { value.deallocate() }
        var size = UInt32(MemoryLayout<Value>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, value) == noErr ? value.pointee : nil
    }
    private static func set<Value>(_ selector: AudioObjectPropertySelector, of device: AudioDeviceID, to value: Value) {
        var address = address(selector)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &address), AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return }
        let status = withUnsafePointer(to: value) { AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Value>.size), $0) }
        if status != noErr { NSLog("Con DualSense: device volume could not be set (%d)", status) }
    }
    private static func play(_ player: AVAudioPlayerNode) throws {
        if let exception = SoleCatchException({ player.play() }) {
            throw NSError(domain: "app.sole.dualsense", code: 1, userInfo: [NSLocalizedDescriptionKey: exception.reason ?? exception.name.rawValue])
        }
    }
    public func submit(_ pcm: Data) -> Bool {
        guard !pcm.isEmpty, pcm.count % 4 == 0, configure(), let player, let format else { return false }
        let admitted = lock.withLock { () -> UUID? in
            guard pending < 4 else { return nil }
            pending += 1
            return generation
        }
        guard let attempt = admitted else { return true }
        guard let buffer = Self.buffer(pcm, format: format) else {
            lock.withLock { pending -= 1 }
            return false
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.lock.withLock {
                if self.generation == attempt { self.pending = max(0, self.pending - 1); self.played += 1 }
            }
        }
        return true
    }
    static func buffer(_ pcm: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard format.channelCount == 4, format.sampleRate == HapticsSound.rate, let actuators = HapticsSound.actuators(pcm) else { return nil }
        let frames = actuators.left.count
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)), let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<frames {
            channels[0][frame] = 0; channels[1][frame] = 0
            channels[2][frame] = actuators.left[frame]; channels[3][frame] = actuators.right[frame]
        }
        return buffer
    }
    private static func usbDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let result = devices.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!) }
        guard result == noErr else { return nil }
        for device in devices {
            address.mSelector = kAudioDevicePropertyTransportType
            var transport: UInt32 = 0; size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr, transport == kAudioDeviceTransportTypeUSB else { continue }
            address.mSelector = kAudioObjectPropertyName
            var name: Unmanaged<CFString>?; size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr, let name else { continue }
            let text = (name.takeRetainedValue() as String).lowercased()
            guard text.contains("dualsense") || text.contains("wireless controller") else { continue }
            address.mSelector = kAudioDevicePropertyStreamConfiguration; address.mScope = kAudioDevicePropertyScopeOutput
            size = 0
            guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { address.mScope = kAudioObjectPropertyScopeGlobal; continue }
            let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { memory.deallocate() }
            let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, memory)
            address.mScope = kAudioObjectPropertyScopeGlobal
            guard status == noErr else { continue }
            let list = UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
            if list.reduce(0, { $0 + Int($1.mNumberChannels) }) >= 4 { return device }
        }
        return nil
    }
}
