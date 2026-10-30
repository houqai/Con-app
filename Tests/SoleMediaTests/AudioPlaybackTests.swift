import AVFoundation
import Testing
@testable import SoleMedia

@Suite struct AudioPlaybackTests {
    @Test func convertsInterleavedStereoWithoutSwappingChannels() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let buffer = try #require(AudioPlayback.buffer([Int16.min, Int16.max, 0, 16384], channels: 2, format: format))
        let data = try #require(buffer.floatChannelData)
        #expect(buffer.frameLength == 2)
        #expect(data[0][0] == -1)
        #expect(data[1][0] > 0.999)
        #expect(data[0][1] == 0)
        #expect(data[1][1] == 0.5)
        #expect(AudioPlayback.buffer([0], channels: 2, format: format) == nil)
    }

    @Test func restartsStoppedEngineEvenWhenPendingQueueIsFull() {
        let output = TestAudioOutput()
        let queue = DispatchQueue(label: "audio-recovery-test")
        let audio = AudioPlayback(output: output, queue: queue)
        send(10, to: audio, queue: queue)
        #expect(output.scheduled == 8)
        queue.sync { output.isRunning = false }
        send(1, to: audio, queue: queue)
        #expect(output.starts == 2)
        #expect(output.scheduled == 9)
        output.completions.prefix(8).forEach { $0() }
        queue.sync {}
        send(10, to: audio, queue: queue)
        #expect(output.scheduled == 16)
        audio.stop(); queue.sync {}
        send(1, to: audio, queue: queue)
        #expect(output.starts == 3)
        #expect(output.scheduled == 17)
    }

    @Test func retriesFailedStartupAndRestartsStoppedPlayer() {
        let output = TestAudioOutput()
        output.failNextStart = true
        let queue = DispatchQueue(label: "audio-startup-test")
        let audio = AudioPlayback(output: output, queue: queue)
        send(1, to: audio, queue: queue, sample: 0)
        #expect(output.scheduled == 0)
        send(1, to: audio, queue: queue, sample: 0)
        #expect(output.scheduled == 1)
        queue.sync { output.isPlaying = false }
        send(1, to: audio, queue: queue, sample: 0)
        #expect(output.starts == 3)
        #expect(output.scheduled == 2)
    }

    @Test func recoversSilentRendererEvenWhenRunningAndPlayingFlagsStayTrue() {
        let output = TestAudioOutput()
        let queue = DispatchQueue(label: "audio-stalled-renderer-test")
        var time: TimeInterval = 10
        let audio = AudioPlayback(output: output, queue: queue, now: { time })
        send(8, to: audio, queue: queue)
        #expect(output.isRunning && output.isPlaying)
        queue.sync { time += 0.3 }
        send(1, to: audio, queue: queue)
        #expect(output.starts == 2 && output.scheduled == 9)
        #expect(audio.snapshot().restarts == 1 && audio.snapshot().pending == 1)
        output.completions.prefix(8).forEach { $0() }
        queue.sync {}
        #expect(audio.snapshot().pending == 1)
        output.completions.last?()
        queue.sync {}
        #expect(audio.snapshot().pending == 0 && audio.snapshot().played == 1)
    }

    @Test func movesToTheNewOutputWhenTheSystemSwitchesDevices() {
        let output = TestAudioOutput()
        let queue = DispatchQueue(label: "audio-route-test")
        let audio = AudioPlayback(output: output, queue: queue)
        send(3, to: audio, queue: queue)
        #expect(output.configured == 1 && output.starts == 1 && output.scheduled == 3)
        output.onRouteChange?()
        queue.sync {}
        #expect(!output.isRunning, "Playback into the old device stops")
        send(2, to: audio, queue: queue)
        #expect(output.configured == 2 && output.starts == 2, "The output is reconfigured on the current default device")
        #expect(output.scheduled == 5 && audio.snapshot().pending == 2)
        audio.stop(); queue.sync {}
        output.onRouteChange?()
        queue.sync {}
        send(1, to: audio, queue: queue)
        #expect(output.configured == 3 && output.scheduled == 6)
    }
}

private func send(_ count: Int, to audio: AudioPlayback, queue: DispatchQueue, sample: Int16 = 100) {
    for _ in 0..<count { [Int16](repeating: sample, count: 960).withUnsafeBufferPointer { audio.submit($0, channels: 2, rate: 48000) } }
    queue.sync {}
}

private final class TestAudioOutput: AudioPlaybackOutput {
    var notificationSource: AnyObject? { nil }
    var onRouteChange: (() -> Void)?
    var configured = 0
    var isRunning = false
    var isPlaying = false
    var starts = 0
    var failNextStart = false
    var scheduled = 0
    var completions: [() -> Void] = []
    func configure(_ format: AVAudioFormat) { configured += 1 }
    func start() throws {
        starts += 1
        if failNextStart { failNextStart = false; throw NSError(domain: "AudioTest", code: 1) }
        isRunning = true; isPlaying = true
    }
    func stop() { isRunning = false; isPlaying = false }
    func schedule(_ buffer: AVAudioPCMBuffer, completion: @escaping () -> Void) {
        scheduled += 1; completions.append(completion)
    }
}
