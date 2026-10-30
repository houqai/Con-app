import Testing
import Foundation
import CConEngine
@testable import SoleEngine

private final class Collected<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ item: T) { lock.withLock { items.append(item) } }
    var all: [T] { lock.withLock { items } }
}

private let ps5Target: UInt32 = ConsoleTarget.ps5v1.rawValue
private let credentials = RemotePlayCredentials(registKey: Array(1...16), morning: Array(17...32), targetValue: ps5Target, serverMAC: [1, 2, 3, 4, 5, 6], consolePIN: 12345678)

@Suite struct RustEngineLinkTests {
    @Test func theLibraryIsLinkedAndSaysItsVersion() {
        let version = RustEngine.version
        #expect(!version.isEmpty)
        #expect(version.split(separator: ".").count == 3, "a version like 0.1.0, not \(version)")
        #expect(SoleEngine.version == version)
    }
    @Test func theLibraryWasBuiltForTheHeaderConUses() {
        #expect(RustEngine.interfaceMatches)
        #expect(SoleEngine.initialize())
    }
    @Test func errorsOfTheEngineBecomeConsErrors() {
        #expect(RustEngine.error(CON_ERR_BAD_CREDENTIAL) == .invalidCredentials)
        guard case .engine(let code, let message) = RustEngine.error(CON_ERR_IO) else { Issue.record("not an engine error"); return }
        #expect(code == CON_ERR_IO && message == "Network error. Check your network connection.")
        guard case .engine(_, let unknown) = RustEngine.error(CON_ERR_PANIC) else { Issue.record("not an engine error"); return }
        #expect(unknown == "Engine error.")
    }
}

@Suite struct RustEventMappingTests {
    private func event(_ type: UInt32, _ fill: (inout ConEvent) -> Void = { _ in }) -> ConEvent {
        var event = ConEvent()
        event.type = type
        fill(&event)
        return event
    }

    @Test func theStreamRuns() {
        guard case .connected = RustMapping.event(event(CON_EVENT_CONNECTED)) else { Issue.record("not connected"); return }
    }
    @Test func theConsoleAsksForTheLoginCode() {
        guard case .loginPINRequired(let incorrect) = RustMapping.event(event(CON_EVENT_PIN_REQUESTED) { $0.data.pin.previous_wrong = 0 }) else { Issue.record("no PIN request"); return }
        #expect(!incorrect)
        guard case .loginPINRequired(let again) = RustMapping.event(event(CON_EVENT_PIN_REQUESTED) { $0.data.pin.previous_wrong = 1 }) else { Issue.record("no PIN request"); return }
        #expect(again)
    }
    @Test func theGamepadsEffects() {
        guard case .rumble(let left, let right) = RustMapping.event(event(CON_EVENT_RUMBLE) { $0.data.rumble = ConRumbleEvent(left: 200, right: 7) }) else { Issue.record("no rumble"); return }
        #expect(left == 200 && right == 7)

        let triggers = event(CON_EVENT_TRIGGER_EFFECTS) { event in
            withUnsafeMutableBytes(of: &event.data.trigger_effects.left) { for index in 0..<11 { $0[index] = UInt8(index + 1) } }
            withUnsafeMutableBytes(of: &event.data.trigger_effects.right) { for index in 0..<11 { $0[index] = UInt8(0x21 + index) } }
        }
        guard case .triggerEffects(let l2, let r2) = RustMapping.event(triggers) else { Issue.record("no trigger effects"); return }
        #expect(l2 == Array(1...11), "the mode byte first, then its ten parameters")
        #expect(r2 == Array(0x21...0x2B))

        guard case .led(let red, let green, let blue) = RustMapping.event(event(CON_EVENT_LIGHT_BAR) { $0.data.light_bar = ConLightBarEvent(r: 1, g: 2, b: 3) }) else { Issue.record("no light"); return }
        #expect(red == 1 && green == 2 && blue == 3)
        guard case .playerIndex(let index) = RustMapping.event(event(CON_EVENT_PLAYER_INDEX) { $0.data.player_index.index = 2 }) else { Issue.record("no player index"); return }
        #expect(index == 2)
        guard case .motionReset = RustMapping.event(event(CON_EVENT_MOTION_RESET)) else { Issue.record("no motion reset"); return }
    }
    @Test func theStrengthOfEffectsKeepsItsNumbers() {
        for (kind, value) in [(CON_INTENSITY_HAPTIC, UInt8(0)), (CON_INTENSITY_TRIGGER, 1), (CON_INTENSITY_HAPTIC, 2), (CON_INTENSITY_TRIGGER, 3)] {
            let mapped = RustMapping.event(event(CON_EVENT_EFFECT_INTENSITY) { $0.data.effect_intensity = ConEffectIntensityEvent(kind: kind, value: value) })
            guard case .effectIntensity(let trigger, let number) = mapped else { Issue.record("no intensity"); return }
            #expect(trigger == (kind == CON_INTENSITY_TRIGGER))
            #expect(number == UInt32(value), "0 off, 1 strong, 2 medium, 3 weak, as DualSenseDriver reads them")
        }
    }
    @Test func theEndOfASession() {
        let stopped = RustMapping.event(event(CON_EVENT_QUIT) { $0.data.quit = ConQuitEvent(text: nil, reason: CON_QUIT_STOPPED, stage: CON_STAGE_STREAMING, is_error: 0) })
        guard case .quit(let reason, let isError, let stage) = stopped else { Issue.record("no quit"); return }
        #expect(!isError && !reason.isEmpty && reason.first?.isUppercase == true)
        #expect(stage == String(cString: con_stage_name(CON_STAGE_STREAMING)) && stage?.isEmpty == false)

        let refused = "Remote Play is used elsewhere"
        let mapped = refused.withCString { text in
            RustMapping.event(event(CON_EVENT_QUIT) { $0.data.quit = ConQuitEvent(text: text, reason: CON_QUIT_STREAM_REMOTE_DISCONNECTED, stage: CON_STAGE_KEY_EXCHANGE, is_error: 1) })
        }
        guard case .quit(let words, let error, let stage) = mapped else { Issue.record("no quit"); return }
        #expect(error)
        #expect(words.hasSuffix(": " + refused), "the console's own words are kept: \(words)")
        #expect(stage == String(cString: con_stage_name(CON_STAGE_KEY_EXCHANGE)))
    }
    @Test func everyStageHasItsOwnName() {
        let stages = [CON_STAGE_UNKNOWN, CON_STAGE_SESSION_REQUEST, CON_STAGE_CONTROL, CON_STAGE_NETWORK_TEST, CON_STAGE_TRANSPORT,
                      CON_STAGE_KEY_EXCHANGE, CON_STAGE_STREAM_INFO, CON_STAGE_STREAMING]
        let names = stages.map(RustMapping.stageName)
        #expect(Set(names).count == stages.count, "\(names)")
        #expect(names.allSatisfy { !$0.isEmpty && !$0.contains("\n") })
        #expect(RustMapping.stageName(999) == RustMapping.stageName(CON_STAGE_UNKNOWN))
    }
    @Test func eventsConDoesNotUseAreLeftOut() {
        for type in [CON_EVENT_LOG, CON_EVENT_STATS, CON_EVENT_NETWORK_TEST, CON_EVENT_STREAM_INFO, CON_EVENT_VIDEO, CON_EVENT_AUDIO, CON_EVENT_HAPTICS, CON_EVENT_KEYBOARD_CLOSED, 999] {
            #expect(RustMapping.event(event(type)) == nil, "event \(type)")
        }
    }

    @Test func videoGoesToTheVideoPathWithItsFrameNumber() {
        let seen = Collected<(bytes: [UInt8], frame: Int32, lost: Int32, recovered: Bool, display: Bool)>()
        let handler: RemotePlaySession.VideoHandler = { buffer, frame, lost, recovered, display in
            seen.add((Array(buffer), frame, lost, recovered, display)); return frame != 9
        }
        var bytes: [UInt8] = [0, 0, 0, 1, 0x40, 1, 2, 3] + Array(repeating: 0, count: 64)
        bytes.withUnsafeMutableBufferPointer { data in
            var video = ConVideoEvent()
            video.data = UnsafePointer(data.baseAddress); video.size = 8; video.padded_size = 72
            video.kind = CON_VIDEO_PARAMETER_SETS; video.frame_index = 5
            #expect(RustMapping.video(video, to: handler))
            video.kind = CON_VIDEO_PICTURE; video.frame_index = 9; video.frames_lost = 2; video.recovered = 1
            #expect(!RustMapping.video(video, to: handler), "the decoder's answer goes back to the engine")
        }
        let all = seen.all
        #expect(all.count == 2)
        #expect(all[0].frame == -1, "parameter sets are frame -1 for Con's path")
        #expect(all[0].bytes == [0, 0, 0, 1, 0x40, 1, 2, 3], "the access unit without the engine's padding")
        #expect(all[1].frame == 9 && all[1].lost == 2 && all[1].recovered)
        #expect(all[0].display && all[1].display, "pictures without the engine's flag are shown")
    }
    @Test func aDecodeOnlyPictureGoesToTheDecoderNotToTheScreen() {
        let seen = Collected<(frame: Int32, lost: Int32, display: Bool)>()
        let handler: RemotePlaySession.VideoHandler = { _, frame, lost, _, display in seen.add((frame, lost, display)); return true }
        var bytes: [UInt8] = [0, 0, 0, 1, 0x02, 1, 2, 3] + Array(repeating: 0, count: 64)
        bytes.withUnsafeMutableBufferPointer { data in
            var video = ConVideoEvent()
            video.data = UnsafePointer(data.baseAddress); video.size = 8; video.padded_size = 72
            video.kind = CON_VIDEO_PICTURE; video.frame_index = 1327; video.recovered = 1
            video.flags = UInt8(CON_VIDEO_FLAG_DECODE_ONLY)
            #expect(RustMapping.video(video, to: handler), "the decoder's answer goes back as for any picture")
            video.frame_index = 1328; video.recovered = 0
            video.flags = UInt8(CON_VIDEO_FLAG_DECODE_ONLY) | 0x80
            #expect(RustMapping.video(video, to: handler))
            video.frame_index = 1336; video.flags = 0
            #expect(RustMapping.video(video, to: handler))
        }
        #expect(seen.all.map(\.frame) == [1327, 1328, 1336])
        #expect(seen.all.map(\.display) == [false, false, true], "the recovery picture is shown again")
        #expect(seen.all.allSatisfy { $0.lost == 0 }, "a hidden picture is not a lost one")
    }
    @Test func theDecodersAnswerIsWrittenIntoTheEvent() {
        let context = RustSessionContext(video: { _, frame, _, _, _ in frame == 1 }, audio: { _, _, _ in }, event: { _ in }, log: { _ in })
        var bytes: [UInt8] = [0, 0, 1, 0x26] + Array(repeating: 0, count: 64)
        bytes.withUnsafeMutableBufferPointer { data in
            for (frame, accepted) in [(UInt16(1), UInt8(1)), (2, 0)] {
                var event = ConEvent()
                event.type = CON_EVENT_VIDEO
                event.data.video.data = UnsafePointer(data.baseAddress); event.data.video.size = 4
                event.data.video.kind = CON_VIDEO_PICTURE; event.data.video.frame_index = frame; event.data.video.accepted = 1
                context.handle(&event)
                #expect(event.data.video.accepted == accepted)
            }
        }
    }
    @Test func decodedSoundGoesOnUndecodedDoesNot() {
        let seen = Collected<(samples: [Int16], channels: Int, rate: Int)>()
        let handler: RemotePlaySession.AudioHandler = { pcm, channels, rate in seen.add((Array(pcm), channels, rate)) }
        var pcm: [Int16] = [1, -1, 2, -2]
        pcm.withUnsafeMutableBufferPointer { samples in
            var audio = ConAudioEvent()
            audio.pcm = UnsafePointer(samples.baseAddress); audio.pcm_count = 4; audio.samples_per_channel = 2
            audio.sample_rate = 48000; audio.channels = 2; audio.decoded = 1
            RustMapping.audio(audio, to: handler)
            audio.decoded = 0
            RustMapping.audio(audio, to: handler)
            audio.decoded = 1; audio.channels = 0
            RustMapping.audio(audio, to: handler)
        }
        #expect(seen.all.count == 1)
        #expect(seen.all.first?.samples == [1, -1, 2, -2] && seen.all.first?.channels == 2 && seen.all.first?.rate == 48000)
    }
    @Test func hapticsInTheSizesTheGamepadTakes() {
        var bytes = [UInt8](repeating: 7, count: 4100)
        bytes.withUnsafeMutableBufferPointer { data in
            var haptics = ConHapticsEvent()
            haptics.pcm = UnsafePointer(data.baseAddress); haptics.sample_rate = 3000; haptics.channels = 2
            haptics.size = 64
            #expect(RustMapping.haptics(haptics) == Data(repeating: 7, count: 64))
            for size in [0, 6, 4100] {
                haptics.size = size
                #expect(RustMapping.haptics(haptics) == nil, "\(size) bytes")
            }
        }
    }
    @MainActor @Test func eventsReachTheMainThreadAndTheLogItsSink() async {
        let lines = Collected<String>()
        let event = await withCheckedContinuation { (continuation: CheckedContinuation<RemotePlaySession.Event, Never>) in
            let context = RustSessionContext(video: { _, _, _, _, _ in true }, audio: { _, _, _ in }, event: { event in
                MainActor.assertIsolated()
                continuation.resume(returning: event)
            }, log: { lines.add($0) })
            "audio header: 2 channels".withCString { text in
                var log = ConEvent(); log.type = CON_EVENT_LOG; log.data.log = ConLogEvent(text: text, level: CON_LOG_INFO)
                context.handle(&log)
            }
            var bytes = [UInt8](repeating: 1, count: 8)
            bytes.withUnsafeMutableBufferPointer { data in
                var haptics = ConEvent(); haptics.type = CON_EVENT_HAPTICS
                haptics.data.haptics.pcm = UnsafePointer(data.baseAddress); haptics.data.haptics.size = 8
                context.handle(&haptics)
            }
        }
        guard case .haptics(let pcm) = event else { Issue.record("not haptics: \(event)"); return }
        #expect(pcm == Data(repeating: 1, count: 8))
        #expect(lines.all == ["audio header: 2 channels"])
    }
    @Test func theRoundTripOfTheStatistics() {
        var stats = ConStats()
        #expect(RustMapping.roundTrip(stats) == nil)
        stats.rtt_latest_us = 12_500; stats.rtt_samples = 4
        let trip = RustMapping.roundTrip(stats)
        #expect(trip?.milliseconds == 12.5 && trip?.count == 4)
    }
}

@Suite struct RustConfigurationMappingTests {
    @Test func theControllerKeepsEveryButtonAndAxis() {
        for (button, bit) in RustMapping.buttons {
            var state = ControllerState()
            state.setButtons(button)
            #expect(RustMapping.controllerState(state).buttons == bit, "\(button)")
        }
        #expect(Set(RustMapping.buttons.map(\.1)).count == 16)
        var state = ControllerState()
        state.setButtons([.cross, .r1, .ps])
        state.setTriggers(l2: 1, r2: 0.5)
        state.setSticks(leftX: 1, leftY: 1, rightX: -1, rightY: -0.5)
        state.setTouch(slot: 0, id: 7, x: -1, y: 1)
        state.setTouch(slot: 1, id: nil)
        state.raw.gyroX = 0.5; state.raw.accelY = 1; state.raw.orientW = 0.25
        let mapped = RustMapping.controllerState(state)
        #expect(mapped.buttons == CON_BUTTON_CROSS | CON_BUTTON_R1 | CON_BUTTON_PS)
        #expect(mapped.l2 == 255 && mapped.r2 == 127)
        #expect(mapped.left_x == 32767 && mapped.left_y == -32767 && mapped.right_x == -32767 && mapped.right_y == 16383)
        #expect(mapped.touches.0.id == 7 && mapped.touches.0.x == 0 && mapped.touches.0.y == 0)
        #expect(mapped.touches.1.id == -1)
        #expect(mapped.gyro.0 == 0.5 && mapped.accel.1 == 1 && mapped.orientation.3 == 0.25)
    }
    @Test func theIdleControllerIsTheEnginesIdle() {
        var idle = ConControllerState()
        #expect(con_controller_state_idle(&idle) == CON_OK)
        let mapped = RustMapping.controllerState(.idle)
        #expect(mapped.buttons == idle.buttons && mapped.l2 == idle.l2 && mapped.r2 == idle.r2)
        #expect(mapped.left_x == idle.left_x && mapped.left_y == idle.left_y && mapped.right_x == idle.right_x && mapped.right_y == idle.right_y)
        #expect(mapped.touches.0.id == idle.touches.0.id && mapped.touches.1.id == idle.touches.1.id)
        #expect(withUnsafeBytes(of: mapped.accel) { Array($0) } == withUnsafeBytes(of: idle.accel) { Array($0) })
        #expect(withUnsafeBytes(of: mapped.orientation) { Array($0) } == withUnsafeBytes(of: idle.orientation) { Array($0) })
        #expect(withUnsafeBytes(of: mapped.gyro) { Array($0) } == withUnsafeBytes(of: idle.gyro) { Array($0) })
    }
    @Test func targetsAreKeptAsConStoresThem() {
        let pairs: [(UInt32, ConsoleTarget)] = [(CON_TARGET_PS4_8, .ps4v8), (CON_TARGET_PS4_9, .ps4v9), (CON_TARGET_PS4_10, .ps4v10), (CON_TARGET_PS5_1, .ps5v1)]
        for (engine, stored) in pairs {
            #expect(RustMapping.storedTarget(engine, isPS5: engine == CON_TARGET_PS5_1) == stored.rawValue)
            #expect(RustMapping.engineTarget(stored: stored.rawValue) == engine)
        }
        #expect(RustMapping.storedTarget(CON_TARGET_UNKNOWN, isPS5: true) == ConsoleTarget.ps5v1.rawValue)
        #expect(RustMapping.storedTarget(CON_TARGET_UNKNOWN, isPS5: false) == ConsoleTarget.ps4v10.rawValue)
        #expect(RustMapping.engineTarget(stored: ConsoleTarget.ps5Unknown.rawValue) == CON_TARGET_PS5_1)
        #expect(RustMapping.engineTarget(stored: ConsoleTarget.ps4Unknown.rawValue) == CON_TARGET_PS4_10)
        #expect(RustMapping.engineTarget(stored: 1_000_050) == CON_TARGET_PS5_1, "any number of a PS5")
    }
    @Test func aConsoleFoundOnTheNetwork() {
        let console = "1.2.3.4".withCString { address in
            "ABCDEF".withCString { id in
                "PS5-123".withCString { name in
                    "25.02".withCString { version in
                        var host = ConDiscoveredHost()
                        host.address = address; host.host_id = id; host.host_name = name; host.system_version = version
                        host.state = CON_CONSOLE_STATE_STANDBY; host.kind = CON_CONSOLE_PS5; host.target = CON_TARGET_PS5_1
                        return RustMapping.console(host)
                    }
                }
            }
        }
        #expect(console.address == "1.2.3.4" && console.hostID == "ABCDEF" && console.name == "PS5-123")
        #expect(console.isPS5 && console.state == .standby && console.systemVersion == "25.02")
        #expect(console.targetValue == ps5Target)
        var bare = ConDiscoveredHost()
        bare.kind = CON_CONSOLE_PS4; bare.state = CON_CONSOLE_STATE_UNKNOWN
        let unknown = RustMapping.console(bare)
        #expect(!unknown.isPS5 && unknown.state == .unknown && unknown.systemVersion == nil && unknown.hostID.isEmpty)
    }
    @Test func aRegistrationGivesTheSameCredentials() {
        var result = ConRegistrationResult()
        result.status = CON_REGIST_OK; result.target = CON_TARGET_PS5_1
        withUnsafeMutableBytes(of: &result.regist_key) { for index in 0..<16 { $0[index] = UInt8(index + 1) } }
        withUnsafeMutableBytes(of: &result.rp_key) { for index in 0..<16 { $0[index] = UInt8(index + 17) } }
        withUnsafeMutableBytes(of: &result.mac) { for index in 0..<6 { $0[index] = UInt8(index + 1) } }
        guard case .success(let made) = RustMapping.credentials(result, pin: 12345678) else { Issue.record("no credentials"); return }
        #expect(made == credentials)
        #expect(made.isPS5)

        result.status = CON_REGIST_INVALID_PIN
        guard case .failure(.engine(let code, let message)) = RustMapping.credentials(result, pin: 1) else { Issue.record("no failure"); return }
        #expect(code == Int32(CON_REGIST_INVALID_PIN) && message == "Registration failed")
        result.status = CON_REGIST_CANCELLED
        guard case .failure(.cancelled) = RustMapping.credentials(result, pin: 1) else { Issue.record("not cancelled"); return }
    }
    @Test func theCodeKeepsItsLeadingZeros() {
        #expect(RustMapping.pinText(1234567) == "01234567")
        #expect(RustMapping.pinText(87654321) == "87654321")
        #expect(RustMapping.pinText(0) == "00000000")
    }
    @Test func aConsoleStreamIsAskedFor() {
        let config = RustMapping.consoleConfig(credentials: credentials, profile: .init(resolution: 1080, fps: 60))
        #expect(config.kind == CON_CONSOLE_PS5 && config.codec == CON_CODEC_H264)
        #expect(config.video_height == 1080 && config.max_fps == 60 && config.bitrate_kbps == 0)
        #expect(config.auto_downgrade == 1 && config.keyboard == 0 && config.network_test == 1)
        #expect(withUnsafeBytes(of: config.regist_key) { Array($0) } == credentials.registKey)
        #expect(withUnsafeBytes(of: config.rp_key) { Array($0) } == credentials.morning)
        let options = RustMapping.options(cloud: nil)
        #expect(options.loss_ceiling == 0.04 && options.dualsense == 1 && options.decode_audio == 1 && options.idr_on_fec_failure == 0)
    }
    @Test func aCloudSlotIsAskedFor() {
        let key = Data((0..<16).map { UInt8($0) })
        let ps4 = CloudStreamSlot(host: "5.6.7.8", port: 2053, packetPrefix: 1, launchSpecification: "spec", sessionID: "id", handshakeKey: key, mtuIn: 1400, mtuOut: 1200, rttMs: 20, isPS5: false)
        let config = RustMapping.cloudConfig(ps4, profile: .init(resolution: 1080, fps: 60))
        #expect(config.port == 2053 && config.prefix == 1 && config.ps5 == 0 && config.codec == CON_CODEC_H264)
        #expect(config.mtu_in == 1400 && config.mtu_out == 1200 && config.max_fps == 60)
        #expect(config.rtt_us == 20_000, "the round trip measured before the stream")
        #expect(withUnsafeBytes(of: config.handshake_key) { Data($0) } == key)
        let options = RustMapping.options(cloud: ps4)
        #expect(options.loss_ceiling == 0.02 && options.dualsense == 0)
        var ps5 = ps4; ps5.isPS5 = true; ps5.packetPrefix = 0
        #expect(RustMapping.cloudConfig(ps5, profile: .init()).codec == CON_CODEC_H265)
        #expect(RustMapping.options(cloud: ps5).loss_ceiling == 0.04 && RustMapping.options(cloud: ps5).dualsense == 1)
        var unmeasured = ps4; unmeasured.rttMs = 0
        #expect(RustMapping.cloudConfig(unmeasured, profile: .init()).rtt_us == 0, "none")
        #expect(RustMapping.options(cloud: ps4).video_capture_path == nil, "no capture unless asked for")
    }
    @Test func theThreadsGetTheirClasses() {
        #expect(RustMapping.threadClass(CON_THREAD_IO) == .interactive, "it receives the stream and hands over the media")
        #expect(RustMapping.threadClass(CON_THREAD_SENDER) == .interactive)
        for role in [CON_THREAD_SESSION, CON_THREAD_CONTROL, CON_THREAD_STATISTICS] { #expect(RustMapping.threadClass(role) == .initiated, "\(role)") }
        for role in [CON_THREAD_DISCOVERY, CON_THREAD_REGISTRATION, CON_THREAD_PROBE, CON_THREAD_CAPTURE, CON_THREAD_HELPER, 0, 99] {
            #expect(RustMapping.threadClass(role) == .unchanged, "\(role)")
        }
    }
}

@Suite struct RustCloudProbeMappingTests {
    private func result(_ status: UInt32, stage: UInt32, rtt: UInt64 = 0, mtuIn: UInt32 = 0, mtuOut: UInt32 = 0, echoed: Bool = false) -> ConCloudProbeResult {
        var result = ConCloudProbeResult()
        result.status = status; result.stage = stage; result.rtt_us = rtt; result.rtt_samples = rtt > 0 ? 5 : 0
        result.mtu_in = mtuIn; result.mtu_out = mtuOut; result.hello_echoed = echoed ? 1 : 0
        return result
    }

    @Test func aCompleteProbeGivesTheMeasurementOfItsResult() {
        let report = RustMapping.probeReport(result(CON_PROBE_OK, stage: CON_PROBE_STAGE_DONE, rtt: 20_400, mtuIn: 1400, mtuOut: 1300, echoed: true))
        #expect(report.measurement == CloudNetworkProbe.Measurement(rttMs: 20, mtuIn: 1400, mtuOut: 1300))
        #expect(report.measurement == CloudNetworkProbe.Measurement.made(rttMicroseconds: 20_400, mtuIn: 1400, mtuOut: 1300))
        #expect(report.stage == 7 && report.status == 0 && report.engineStage == Int(CON_PROBE_STAGE_DONE))
    }
    @Test func aDatacenterThatDoesNotAnswerTheMTUTestsKeepsTheDefaults() {
        let none = RustMapping.probeReport(result(CON_PROBE_OK, stage: CON_PROBE_STAGE_DONE, rtt: 300, echoed: true))
        #expect(none.measurement == CloudNetworkProbe.Measurement(rttMs: 1, mtuIn: 1454, mtuOut: 1254), "under a millisecond counts as one")
        #expect(none.stage == 5)
        let inOnly = RustMapping.probeReport(result(CON_PROBE_OK, stage: CON_PROBE_STAGE_DONE, rtt: 9_500, mtuIn: 1100))
        #expect(inOnly.measurement == CloudNetworkProbe.Measurement(rttMs: 10, mtuIn: 1100, mtuOut: 1100), "out no larger than in")
        #expect(inOnly.stage == 6)
        let outOfRange = RustMapping.probeReport(result(CON_PROBE_OK, stage: CON_PROBE_STAGE_DONE, rtt: 5_000, mtuIn: 9000, mtuOut: 100))
        #expect(outOfRange.measurement == CloudNetworkProbe.Measurement(rttMs: 5, mtuIn: 1454, mtuOut: 1254))
    }
    @Test func aFailedTestHasNoMeasurementAndSaysHowFarItGot() {
        let silent = RustMapping.probeReport(result(CON_PROBE_NO_CONNECTION, stage: CON_PROBE_STAGE_CONNECT))
        #expect(silent.measurement == nil && silent.stage == 0 && silent.status == Int(CON_PROBE_NO_CONNECTION))
        #expect(RustMapping.probeReport(result(CON_PROBE_NO_RTT, stage: CON_PROBE_STAGE_RTT, echoed: true)).stage == 3)
        #expect(RustMapping.probeReport(result(CON_PROBE_NO_RTT, stage: CON_PROBE_STAGE_RTT)).stage == 2)
        #expect(RustMapping.probeReport(result(CON_PROBE_NETWORK, stage: CON_PROBE_STAGE_HELLO)).stage == 1)
        #expect(RustMapping.probeReport(result(CON_PROBE_HOST_NOT_FOUND, stage: CON_PROBE_STAGE_CONNECT)).stage == 0)
        #expect(RustMapping.probeReport(result(CON_PROBE_CANCELLED, stage: CON_PROBE_STAGE_MTU_IN, rtt: 20_000)).measurement == nil)
        #expect(RustMapping.probeReport(result(CON_PROBE_OK, stage: CON_PROBE_STAGE_DONE, rtt: 70_000_000)).measurement == nil, "a minute is no round trip")
    }
    @Test func theProbeConfigKeepsTheEngineDefaults() {
        let config = RustMapping.probeConfig(port: 2053, packetPrefix: 1)
        var defaults = ConCloudProbeConfig()
        _ = con_cloud_probe_config_default(&defaults)
        #expect(config.port == 2053 && config.prefix == 1 && config.measure_mtu == 1)
        #expect(config.connect_timeout_ms == defaults.connect_timeout_ms && config.pings == defaults.pings)
        #expect(RustMapping.probeConfig(port: 1, packetPrefix: 0, connectTimeoutMs: 300).connect_timeout_ms == 300)
    }
    @Test func badInputsAreRefusedBeforeTheEngine() {
        for (host, port, credential) in [("", UInt16(1), "k"), ("127.0.0.1", 0, "k"), ("127.0.0.1", 1, ""), ("a\0b", 1, "k")] {
            let report = CloudNetworkProbe.run(host: host, port: port, credential: credential)
            #expect(report.status == -1 && report.measurement == nil && report.engineStage == nil)
        }
    }
    @Test(.timeLimit(.minutes(1))) func aSilentDatacenterIsNotConnected() throws {
        let silent = try SilentPort()
        let report = RustCloudProbe.run(host: "127.0.0.1", port: silent.port, credential: "credential", packetPrefix: 0, connectTimeoutMs: 400)
        #expect(report.measurement == nil)
        #expect(report.status == Int(CON_PROBE_NO_CONNECTION) && report.stage == 0 && report.engineStage == Int(CON_PROBE_STAGE_CONNECT), "\(report)")
        withExtendedLifetime(silent) {}
    }
    @Test(.timeLimit(.minutes(1))) func severalProbesRunAtOnce() async throws {
        let silent = try SilentPort()
        let port = silent.port
        let reports = await withTaskGroup(of: CloudNetworkProbe.Report.self) { group in
            for _ in 0..<3 { group.addTask { RustCloudProbe.run(host: "127.0.0.1", port: port, credential: "credential", packetPrefix: 1, connectTimeoutMs: 300) } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(reports.count == 3 && reports.allSatisfy { $0.status == Int(CON_PROBE_NO_CONNECTION) })
        withExtendedLifetime(silent) {}
    }
}

@Suite(.serialized) struct RustEngineLifecycleTests {
    @Test func badSecretsAreRefusedBeforeTheEngine() {
        #expect(throws: EngineError.invalidCredentials) {
            _ = try RemotePlaySession(host: "127.0.0.1", credentials: RemotePlayCredentials(registKey: [1], morning: [], targetValue: ps5Target, serverMAC: [], consolePIN: 0),
                                      onVideo: { _, _, _, _, _ in true }, onEvent: { _ in })
        }
        let slot = CloudStreamSlot(host: "127.0.0.1", port: 9, packetPrefix: 0, launchSpecification: "spec", sessionID: "id", handshakeKey: Data([1, 2]), mtuIn: 0, mtuOut: 0, rttMs: 1)
        #expect(throws: EngineError.invalidCredentials) {
            _ = try RemotePlaySession(cloud: slot, onVideo: { _, _, _, _, _ in true }, onEvent: { _ in })
        }
    }
    @MainActor @Test(.timeLimit(.minutes(1))) func aConsoleThatIsNotThereEndsTheSessionWithAnError() async throws {
        let (events, sink) = AsyncStream.makeStream(of: RemotePlaySession.Event.self)
        let session = try RemotePlaySession(host: "127.0.0.1", credentials: credentials,
                                            onVideo: { _, _, _, _, _ in true }, onEvent: { sink.yield($0) })
        try session.start()
        #expect(session.roundTrip() == nil, "nothing measured before a stream")
        session.setControllerState(.idle)
        session.requestKeyframe()
        var ending: (reason: String, isError: Bool)?
        for await event in events {
            if case .quit(let reason, let isError, _) = event { ending = (reason, isError); break }
        }
        #expect(ending?.isError == true, "\(String(describing: ending))")
        #expect(ending?.reason.isEmpty == false)
        session.stop()
        session.stop()
        session.submitLoginPIN("1234")
    }
    @MainActor @Test(.timeLimit(.minutes(1))) func aSessionStoppedByConEndsWithoutAnError() async throws {
        let (events, sink) = AsyncStream.makeStream(of: RemotePlaySession.Event.self)
        let key = Data(repeating: 3, count: 16)
        let silent = try SilentPort()
        let slot = CloudStreamSlot(host: "127.0.0.1", port: silent.port, packetPrefix: 0, launchSpecification: "{}", sessionID: "test", handshakeKey: key, mtuIn: 1454, mtuOut: 1254, rttMs: 1)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("con-capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let capture = folder.appendingPathComponent("video-capture.bin")
        let session = try RemotePlaySession(cloud: slot, videoCapturePath: capture.path, onVideo: { _, _, _, _, _ in true }, onEvent: { sink.yield($0) })
        try session.start()
        try await Task.sleep(nanoseconds: 200_000_000)
        #if os(macOS) || os(Windows)
        #expect(RustEngine.threads.raised(CON_THREAD_IO) > 0)
        #expect(RustEngine.threads.refused(CON_THREAD_IO) == 0)
        #else
        #expect(RustEngine.threads.raised(CON_THREAD_IO) + RustEngine.threads.refused(CON_THREAD_IO) > 0)
        #endif
        Task.detached { session.stop() }
        var ending: (reason: String, isError: Bool)?
        for await event in events {
            if case .quit(let reason, let isError, _) = event { ending = (reason, isError); break }
        }
        #expect(ending?.isError == false, "\(String(describing: ending))")
        session.stop()
        let header = try Data(contentsOf: capture).prefix(8)
        #expect(header == Data("CONVCAP1".utf8))
        withExtendedLifetime(silent) {}
    }
    @Test(.timeLimit(.minutes(1))) func aRegistrationNobodyAnswersEndsAndIsNotStartedAgain() async {
        let registration = RemotePlayRegistration()
        do {
            _ = try await registration.register(host: "127.0.0.1", targetValue: ps5Target, psnAccountID: Array(repeating: 0, count: 8), pin: 12345678)
            Issue.record("registered with nobody")
        } catch let error as EngineError {
            switch error {
            case .engine(_, "Registration failed"): break
            default: Issue.record("unexpected \(error)")
            }
        } catch { Issue.record("unexpected \(error)") }
        await #expect(throws: EngineError.cancelled) {
            _ = try await registration.register(host: "127.0.0.1", targetValue: ps5Target, psnAccountID: Array(repeating: 0, count: 8), pin: 1)
        }
    }
    @MainActor @Test func theSearchStartsAndStops() async throws {
        let discovery = ConsoleDiscovery { _ in }
        discovery.start()
        #expect(discovery.isRunning, "the engine started the search")
        try await Task.sleep(nanoseconds: 300_000_000)
        discovery.stop()
        #expect(!discovery.isRunning)
        discovery.stop()
    }
}
