import CConEngine
import Foundation

enum RustEngine {
    static var version: String { String(cString: con_engine_version()) }
    static var interfaceMatches: Bool { con_engine_abi_version() == CON_ENGINE_ABI_VERSION }

    static func prepare() { _ = threadCallbackInstalled }
    private static let threadCallbackInstalled: Bool = {
        con_set_thread_callback({ _, role, _ in RustEngine.threadStarted(role: role) }, nil) == CON_OK
    }()

    private static func threadStarted(role: UInt32) {
        switch RustMapping.threadClass(role) {
        case .interactive:
            threads.record(role: role, raised: con_thread_set_interactive() == CON_OK)
        case .initiated:
            #if canImport(Darwin)
            threads.record(role: role, raised: pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0) == 0)
            #endif
        case .unchanged:
            break
        }
    }

    final class ThreadLedger: @unchecked Sendable {
        private let lock = NSLock()
        private var raised: [UInt32: Int] = [:]
        private var refused: [UInt32: Int] = [:]
        func record(role: UInt32, raised done: Bool) {
            lock.withLock { if done { raised[role, default: 0] += 1 } else { refused[role, default: 0] += 1 } }
        }
        func raised(_ role: UInt32) -> Int { lock.withLock { raised[role] ?? 0 } }
        func refused(_ role: UInt32) -> Int { lock.withLock { refused[role] ?? 0 } }
    }
    static let threads = ThreadLedger()

    static func error(_ code: Int32) -> EngineError {
        let message: String
        switch code {
        case CON_ERR_INVALID_ARGUMENT: message = "The engine did not accept the connection settings."
        case CON_ERR_NOT_READY: message = "The engine is not ready yet. Try again."
        case CON_ERR_IO: message = "Network error. Check your network connection."
        case CON_ERR_UNSUPPORTED: message = "The engine does not support this operation."
        case CON_ERR_BAD_CREDENTIAL: return .invalidCredentials
        case CON_ERR_SEND_FAILED: message = "Could not send data."
        default: message = "Engine error."
        }
        return .engine(code: code, message: message)
    }
}

enum RustMapping {
    static func text(_ pointer: UnsafePointer<CChar>?) -> String? { pointer.map { String(cString: $0) } }

    static func storedTarget(_ target: UInt32, isPS5: Bool) -> UInt32 {
        let value: ConsoleTarget
        switch target {
        case CON_TARGET_PS4_8: value = .ps4v8
        case CON_TARGET_PS4_9: value = .ps4v9
        case CON_TARGET_PS4_10: value = .ps4v10
        case CON_TARGET_PS5_1: value = .ps5v1
        default: value = isPS5 ? .ps5v1 : .ps4v10
        }
        return value.rawValue
    }

    static func engineTarget(stored value: UInt32) -> UInt32 {
        switch ConsoleTarget(rawValue: value) {
        case .ps4v8: return CON_TARGET_PS4_8
        case .ps4v9: return CON_TARGET_PS4_9
        case .ps4v10, .ps4Unknown: return CON_TARGET_PS4_10
        default: return ConsoleTarget.isPS5(value) ? CON_TARGET_PS5_1 : CON_TARGET_PS4_10
        }
    }

    static func console(_ host: ConDiscoveredHost) -> DiscoveredConsole {
        let isPS5 = host.kind == CON_CONSOLE_PS5
        let state: DiscoveredConsole.State
        switch host.state {
        case CON_CONSOLE_STATE_READY: state = .ready
        case CON_CONSOLE_STATE_STANDBY: state = .standby
        default: state = .unknown
        }
        let version = text(host.system_version)
        return DiscoveredConsole(hostID: text(host.host_id) ?? "", name: text(host.host_name) ?? "", address: text(host.address) ?? "",
                                 isPS5: isPS5, state: state, systemVersion: version?.isEmpty == false ? version : nil,
                                 targetValue: storedTarget(host.target, isPS5: isPS5))
    }

    static func pinText(_ pin: UInt32) -> String {
        let digits = String(pin)
        return String(repeating: "0", count: max(0, 8 - digits.count)) + digits
    }

    static func credentials(_ result: ConRegistrationResult, pin: UInt32) -> Result<RemotePlayCredentials, EngineError> {
        switch result.status {
        case CON_REGIST_OK:
            let credentials = RemotePlayCredentials(
                registKey: withUnsafeBytes(of: result.regist_key) { Array($0) },
                morning: withUnsafeBytes(of: result.rp_key) { Array($0) },
                targetValue: storedTarget(result.target, isPS5: result.target == CON_TARGET_PS5_1),
                serverMAC: withUnsafeBytes(of: result.mac) { Array($0) },
                consolePIN: pin)
            return credentials.valid ? .success(credentials) : .failure(.invalidCredentials)
        case CON_REGIST_CANCELLED:
            return .failure(.cancelled)
        default:
            return .failure(.engine(code: Int32(bitPattern: result.status), message: "Registration failed"))
        }
    }

    static func consoleConfig(credentials: RemotePlayCredentials, profile: RemotePlaySession.VideoProfile) -> ConConsoleConfig {
        var config = ConConsoleConfig()
        _ = con_console_config_default(&config)
        config.kind = credentials.isPS5 ? CON_CONSOLE_PS5 : CON_CONSOLE_PS4
        config.codec = CON_CODEC_H264
        config.video_height = UInt32(clamping: profile.resolution)
        config.max_fps = UInt32(clamping: profile.fps)
        config.auto_downgrade = 1
        config.keyboard = 0
        copy(credentials.registKey, into: &config.regist_key)
        copy(credentials.morning, into: &config.rp_key)
        return config
    }

    static func cloudConfig(_ slot: CloudStreamSlot, profile: RemotePlaySession.VideoProfile) -> ConCloudConfig {
        var config = ConCloudConfig()
        _ = con_cloud_config_default(&config)
        config.codec = slot.isPS5 ? CON_CODEC_H265 : CON_CODEC_H264
        config.max_fps = UInt32(clamping: profile.fps)
        config.mtu_in = UInt32(clamping: slot.mtuIn)
        config.mtu_out = UInt32(clamping: slot.mtuOut)
        config.rtt_us = slot.rttMs > 0 ? UInt32(clamping: slot.rttMs * 1000) : 0
        config.port = slot.port
        config.prefix = slot.packetPrefix
        config.ps5 = slot.isPS5 ? 1 : 0
        copy(slot.handshakeKey, into: &config.handshake_key)
        return config
    }

    static func copy<Field>(_ bytes: some Sequence<UInt8>, into field: inout Field) {
        withUnsafeMutableBytes(of: &field) { raw in
            for (index, byte) in bytes.enumerated() where index < raw.count { raw[index] = byte }
        }
    }

    static func options(cloud slot: CloudStreamSlot?) -> ConSessionOptions {
        var options = ConSessionOptions()
        _ = con_session_options_default(&options)
        options.loss_ceiling = slot?.reportedLossLimit ?? 0.04
        options.dualsense = slot.map { $0.isPS5 ? 1 : 0 } ?? 1
        options.log_level = CON_LOG_INFO
        options.stats_interval_ms = 0
        options.idr_on_fec_failure = 0
        options.decode_audio = 1
        return options
    }

    static let buttons: [(ControllerState.Button, UInt32)] = [
        (.cross, CON_BUTTON_CROSS), (.circle, CON_BUTTON_CIRCLE), (.square, CON_BUTTON_SQUARE), (.triangle, CON_BUTTON_TRIANGLE),
        (.dpadLeft, CON_BUTTON_LEFT), (.dpadRight, CON_BUTTON_RIGHT), (.dpadUp, CON_BUTTON_UP), (.dpadDown, CON_BUTTON_DOWN),
        (.l1, CON_BUTTON_L1), (.r1, CON_BUTTON_R1), (.l3, CON_BUTTON_L3), (.r3, CON_BUTTON_R3),
        (.options, CON_BUTTON_OPTIONS), (.share, CON_BUTTON_SHARE), (.touchpad, CON_BUTTON_TOUCHPAD), (.ps, CON_BUTTON_PS),
    ]

    static func controllerState(_ state: ControllerState) -> ConControllerState {
        let raw = state.raw
        let pressed = ControllerState.Button(rawValue: raw.buttons)
        var out = ConControllerState()
        out.buttons = buttons.reduce(0) { pressed.contains($1.0) ? $0 | $1.1 : $0 }
        out.left_x = raw.leftX; out.left_y = raw.leftY
        out.right_x = raw.rightX; out.right_y = raw.rightY
        out.l2 = raw.l2; out.r2 = raw.r2
        out.touches.0 = ConTouch(id: Int16(raw.touches.0.id), x: raw.touches.0.x, y: raw.touches.0.y)
        out.touches.1 = ConTouch(id: Int16(raw.touches.1.id), x: raw.touches.1.x, y: raw.touches.1.y)
        out.gyro = (raw.gyroX, raw.gyroY, raw.gyroZ)
        out.accel = (raw.accelX, raw.accelY, raw.accelZ)
        out.orientation = (raw.orientX, raw.orientY, raw.orientZ, raw.orientW)
        return out
    }

    static func event(_ event: ConEvent) -> RemotePlaySession.Event? {
        switch event.type {
        case CON_EVENT_CONNECTED:
            return .connected
        case CON_EVENT_PIN_REQUESTED:
            return .loginPINRequired(incorrect: event.data.pin.previous_wrong != 0)
        case CON_EVENT_RUMBLE:
            return .rumble(left: event.data.rumble.left, right: event.data.rumble.right)
        case CON_EVENT_TRIGGER_EFFECTS:
            let effects = event.data.trigger_effects
            return .triggerEffects(left: withUnsafeBytes(of: effects.left) { Array($0) }, right: withUnsafeBytes(of: effects.right) { Array($0) })
        case CON_EVENT_LIGHT_BAR:
            let light = event.data.light_bar
            return .led(red: light.r, green: light.g, blue: light.b)
        case CON_EVENT_PLAYER_INDEX:
            return .playerIndex(event.data.player_index.index)
        case CON_EVENT_EFFECT_INTENSITY:
            let intensity = event.data.effect_intensity
            return .effectIntensity(trigger: intensity.kind == CON_INTENSITY_TRIGGER, value: UInt32(intensity.value))
        case CON_EVENT_MOTION_RESET:
            return .motionReset
        case CON_EVENT_QUIT:
            let quit = event.data.quit
            return .quit(reason: quitText(reason: quit.reason, text: text(quit.text)), isError: quit.is_error != 0, stage: stageName(quit.stage))
        default:
            return nil
        }
    }

    static func quitText(reason: UInt32, text: String?) -> String {
        let name = String(cString: con_quit_reason_name(reason))
        let reason = name.prefix(1).uppercased() + name.dropFirst()
        guard let text, !text.isEmpty else { return reason }
        return "\(reason): \(text)"
    }

    static func stageName(_ stage: UInt32) -> String { String(cString: con_stage_name(stage)) }

    static func video(_ video: ConVideoEvent, to handler: RemotePlaySession.VideoHandler) -> Bool {
        guard let data = video.data, video.size > 0 else { return false }
        let frame: Int32 = video.kind == CON_VIDEO_PARAMETER_SETS ? -1 : Int32(video.frame_index)
        let display = video.flags & UInt8(CON_VIDEO_FLAG_DECODE_ONLY) == 0
        return handler(UnsafeBufferPointer(start: data, count: video.size), frame, Int32(clamping: video.frames_lost), video.recovered != 0, display)
    }

    static func audio(_ audio: ConAudioEvent, to handler: RemotePlaySession.AudioHandler) {
        let channels = Int(audio.channels), rate = Int(audio.sample_rate)
        guard audio.decoded != 0, let pcm = audio.pcm, audio.pcm_count > 0, (1...8).contains(channels),
              audio.samples_per_channel <= 5760, (8000...192000).contains(rate) else { return }
        handler(UnsafeBufferPointer(start: pcm, count: audio.pcm_count), channels, rate)
    }

    static func haptics(_ haptics: ConHapticsEvent) -> Data? {
        guard let pcm = haptics.pcm, haptics.size > 0, haptics.size <= 4096, haptics.size % 4 == 0 else { return nil }
        return Data(bytes: pcm, count: haptics.size)
    }

    static func roundTrip(_ stats: ConStats) -> (milliseconds: Double, count: UInt64)? {
        stats.rtt_samples > 0 ? (Double(stats.rtt_latest_us) / 1000, stats.rtt_samples) : nil
    }

    enum ThreadClass: Equatable { case interactive, initiated, unchanged }

    static func threadClass(_ role: UInt32) -> ThreadClass {
        switch role {
        case CON_THREAD_IO, CON_THREAD_SENDER: return .interactive
        case CON_THREAD_SESSION, CON_THREAD_CONTROL, CON_THREAD_STATISTICS: return .initiated
        default: return .unchanged
        }
    }

    static func probeConfig(port: UInt16, packetPrefix: UInt8, connectTimeoutMs: UInt32 = 0) -> ConCloudProbeConfig {
        var config = ConCloudProbeConfig()
        _ = con_cloud_probe_config_default(&config)
        config.port = port
        config.prefix = packetPrefix
        config.measure_mtu = 1
        if connectTimeoutMs > 0 { config.connect_timeout_ms = connectTimeoutMs }
        return config
    }

    static func probeReport(_ result: ConCloudProbeResult) -> CloudNetworkProbe.Report {
        let measurement = result.status == CON_PROBE_OK
            ? CloudNetworkProbe.Measurement.made(rttMicroseconds: result.rtt_us, mtuIn: result.mtu_in, mtuOut: result.mtu_out) : nil
        return CloudNetworkProbe.Report(measurement: measurement, stage: probeStage(result), status: Int(result.status), engineStage: Int(result.stage))
    }

    static func probeStage(_ result: ConCloudProbeResult) -> Int {
        if result.status == CON_PROBE_OK, result.rtt_us > 0 {
            return result.mtu_in == 0 ? 5 : result.mtu_out == 0 ? 6 : 7
        }
        switch result.stage {
        case CON_PROBE_STAGE_HELLO: return result.hello_echoed != 0 ? 3 : 1
        case CON_PROBE_STAGE_RTT: return result.hello_echoed != 0 ? 3 : 2
        case CON_PROBE_STAGE_MTU_IN: return 5
        case CON_PROBE_STAGE_MTU_OUT: return 6
        case CON_PROBE_STAGE_DONE: return 7
        default: return 0
        }
    }
}

enum RustCloudProbe {
    static func run(host: String, port: UInt16, credential: String, packetPrefix: UInt8, connectTimeoutMs: UInt32 = 0) -> CloudNetworkProbe.Report {
        guard CloudNetworkProbe.acceptable(host: host, port: port, credential: credential) else {
            return CloudNetworkProbe.Report(measurement: nil, stage: 0, status: -1)
        }
        RustEngine.prepare()
        var config = RustMapping.probeConfig(port: port, packetPrefix: packetPrefix, connectTimeoutMs: connectTimeoutMs)
        var result = ConCloudProbeResult()
        let code = host.withCString { host in credential.withCString { key in
            config.address = host; config.credential = key
            return con_cloud_probe_run(&config, &result)
        }}
        guard code == CON_OK else { return CloudNetworkProbe.Report(measurement: nil, stage: 0, status: Int(code)) }
        return RustMapping.probeReport(result)
    }
}
