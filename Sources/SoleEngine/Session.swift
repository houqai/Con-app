import CConEngine
import Foundation

public struct CloudStreamSlot: Sendable {
    public var isPS5: Bool
    public var host: String
    public var port: UInt16
    public var packetPrefix: UInt8
    public var launchSpecification: String
    public var sessionID: String
    public var handshakeKey: Data
    public var mtuIn: Int
    public var mtuOut: Int
    public var rttMs: Int
    public var reportedLossLimit: Double { isPS5 ? 0.04 : 0.02 }
    public init(host: String, port: UInt16, packetPrefix: UInt8, launchSpecification: String, sessionID: String, handshakeKey: Data, mtuIn: Int, mtuOut: Int, rttMs: Int, isPS5: Bool = true) {
        self.isPS5 = isPS5
        self.host = host; self.port = port; self.packetPrefix = packetPrefix; self.launchSpecification = launchSpecification
        self.sessionID = sessionID; self.handshakeKey = handshakeKey; self.mtuIn = mtuIn; self.mtuOut = mtuOut; self.rttMs = rttMs
    }
}

public final class RemotePlaySession {
    public struct VideoProfile: Sendable {
        public var resolution: Int
        public var fps: Int
        public init(resolution: Int = 1080, fps: Int = 60) { self.resolution = resolution; self.fps = fps }
    }

    public enum Event: Sendable {
        case connected
        case rumble(left: UInt8, right: UInt8)
        case triggerEffects(left: [UInt8], right: [UInt8])
        case led(red: UInt8, green: UInt8, blue: UInt8)
        case playerIndex(UInt8)
        case haptics(Data)
        case effectIntensity(trigger: Bool, value: UInt32)
        case motionReset
        case loginPINRequired(incorrect: Bool)
        case quit(reason: String, isError: Bool, stage: String? = nil)
    }

    public typealias VideoHandler = @Sendable (_ buffer: UnsafeBufferPointer<UInt8>, _ frame: Int32, _ framesLost: Int32, _ recovered: Bool, _ display: Bool) -> Bool

    public typealias AudioHandler = @Sendable (_ pcm: UnsafeBufferPointer<Int16>, _ channels: Int, _ sampleRate: Int) -> Void

    private enum Target {
        case console(host: String, credentials: RemotePlayCredentials, profile: VideoProfile)
        case cloud(CloudStreamSlot, profile: VideoProfile)

        var cloudSlot: CloudStreamSlot? {
            if case .cloud(let slot, _) = self { return slot }
            return nil
        }
    }
    private let target: Target
    private let context: RustSessionContext
    private let videoCapturePath: String?
    private let condition = NSCondition()
    private var handle: OpaquePointer?
    private var users = 0
    private var started = false

    public init(
        host: String,
        credentials: RemotePlayCredentials,
        profile: VideoProfile = VideoProfile(),
        videoCapturePath: String? = nil,
        logSink: @escaping @Sendable (String) -> Void = { _ in },
        onVideo: @escaping VideoHandler,
        onAudio: @escaping AudioHandler = { _, _, _ in },
        onEvent: @escaping @MainActor (Event) -> Void
    ) throws {
        guard credentials.valid, !host.isEmpty, !host.contains("\0") else { throw EngineError.invalidCredentials }
        target = .console(host: host, credentials: credentials, profile: profile)
        self.videoCapturePath = Self.usablePath(videoCapturePath)
        context = RustSessionContext(video: onVideo, audio: onAudio, event: onEvent, log: logSink)
    }

    public init(
        cloud slot: CloudStreamSlot,
        profile: VideoProfile = VideoProfile(),
        videoCapturePath: String? = nil,
        logSink: @escaping @Sendable (String) -> Void = { _ in },
        onVideo: @escaping VideoHandler,
        onAudio: @escaping AudioHandler = { _, _, _ in },
        onEvent: @escaping @MainActor (Event) -> Void
    ) throws {
        guard slot.port != 0, slot.handshakeKey.count == 16, !slot.launchSpecification.isEmpty,
              !slot.sessionID.isEmpty, slot.sessionID.utf8.count <= 127, !slot.host.isEmpty,
              !slot.launchSpecification.contains("\0"), !slot.sessionID.contains("\0"), !slot.host.contains("\0") else { throw EngineError.invalidCredentials }
        target = .cloud(slot, profile: profile)
        self.videoCapturePath = Self.usablePath(videoCapturePath)
        context = RustSessionContext(video: onVideo, audio: onAudio, event: onEvent, log: logSink)
    }

    private static func usablePath(_ path: String?) -> String? {
        path.flatMap { $0.isEmpty || $0.contains("\0") ? nil : $0 }
    }

    private static let callback: ConEventCallback = { user, event in
        guard let user, let event else { return }
        let context = Unmanaged<RustSessionContext>.fromOpaque(user).takeUnretainedValue()
        context.handle(event)
        if event.pointee.type == CON_EVENT_QUIT { Unmanaged<RustSessionContext>.fromOpaque(user).release() }
    }

    public func start() throws {
        condition.lock(); defer { condition.unlock() }
        guard !started else { return }
        RustEngine.prepare()
        let user = Unmanaged.passRetained(context).toOpaque()
        var session: OpaquePointer?
        var options = RustMapping.options(cloud: target.cloudSlot)
        let code: Int32 = Self.withOptionalCString(videoCapturePath) { capture in
            options.video_capture_path = capture
            switch target {
            case .console(let host, let credentials, let profile):
                var config = RustMapping.consoleConfig(credentials: credentials, profile: profile)
                return host.withCString { host in
                    config.host = host
                    return con_session_start_console(&config, &options, Self.callback, user, &session)
                }
            case .cloud(let slot, let profile):
                var config = RustMapping.cloudConfig(slot, profile: profile)
                return slot.host.withCString { host in
                    slot.sessionID.withCString { sessionID in
                        slot.launchSpecification.withCString { specification in
                            config.address = host; config.session_id = sessionID; config.launch_spec = specification
                            return con_session_start_cloud(&config, &options, Self.callback, user, &session)
                        }
                    }
                }
            }
        }
        guard code == CON_OK, let session else {
            Unmanaged<RustSessionContext>.fromOpaque(user).release()
            throw RustEngine.error(code == CON_OK ? CON_ERR_PANIC : code)
        }
        handle = session
        started = true
        _ = con_session_set_reference_repair(session, CON_MISSING_REFERENCE_REPAIR_HIDE)
        if let videoCapturePath {
            let audio = URL(fileURLWithPath: videoCapturePath).deletingLastPathComponent().appendingPathComponent(VideoCaptureChoice.audioFileName).path
            try? FileManager.default.removeItem(atPath: audio)
            _ = audio.withCString { con_session_set_audio_capture(session, $0) }
        }
    }

    private static func withOptionalCString<T>(_ text: String?, _ body: (UnsafePointer<CChar>?) -> T) -> T {
        guard let text else { return body(nil) }
        return text.withCString { body($0) }
    }

    @discardableResult private func withSession<T>(_ body: (OpaquePointer) -> T) -> T? {
        condition.lock()
        guard let handle else { condition.unlock(); return nil }
        users += 1
        condition.unlock()
        defer {
            condition.lock(); users -= 1
            if users == 0 { condition.broadcast() }
            condition.unlock()
        }
        return body(handle)
    }

    public func stop() {
        condition.lock()
        let session = handle
        handle = nil
        while users > 0 { condition.wait() }
        condition.unlock()
        if let session { con_session_free(session) }
    }

    public func submitLoginPIN(_ pin: String) { withSession { session in pin.withCString { _ = con_session_submit_pin(session, $0) } } }

    public func requestKeyframe() { withSession { _ = con_session_request_keyframe($0) } }

    public func roundTrip() -> (milliseconds: Double, count: UInt64)? {
        withSession { session -> (milliseconds: Double, count: UInt64)? in
            var stats = ConStats()
            guard con_session_stats(session, &stats) == CON_OK else { return nil }
            return RustMapping.roundTrip(stats)
        } ?? nil
    }

    public func hiddenPictures() -> (frames: UInt64, runs: UInt64)? {
        withSession { session -> (frames: UInt64, runs: UInt64)? in
            var frames: UInt64 = 0, runs: UInt64 = 0
            guard con_session_video_hidden(session, &frames, &runs) == CON_OK else { return nil }
            return (frames, runs)
        } ?? nil
    }

    public func setControllerState(_ state: ControllerState) {
        var raw = RustMapping.controllerState(state)
        withSession { _ = con_session_set_controller_state($0, &raw) }
    }

    deinit { stop() }
}

final class RustSessionContext: @unchecked Sendable {
    let videoHandler: RemotePlaySession.VideoHandler
    let audioHandler: RemotePlaySession.AudioHandler
    let eventHandler: @MainActor (RemotePlaySession.Event) -> Void
    let logSink: @Sendable (String) -> Void

    init(video: @escaping RemotePlaySession.VideoHandler, audio: @escaping RemotePlaySession.AudioHandler,
         event: @escaping @MainActor (RemotePlaySession.Event) -> Void, log: @escaping @Sendable (String) -> Void) {
        videoHandler = video; audioHandler = audio; eventHandler = event; logSink = log
    }

    func handle(_ event: UnsafeMutablePointer<ConEvent>) {
        switch event.pointee.type {
        case CON_EVENT_VIDEO:
            event.pointee.data.video.accepted = RustMapping.video(event.pointee.data.video, to: videoHandler) ? 1 : 0
        case CON_EVENT_AUDIO:
            RustMapping.audio(event.pointee.data.audio, to: audioHandler)
        case CON_EVENT_HAPTICS:
            guard let pcm = RustMapping.haptics(event.pointee.data.haptics) else { return }
            post(.haptics(pcm))
        case CON_EVENT_LOG:
            if let line = RustMapping.text(event.pointee.data.log.text) { logSink(line) }
        default:
            guard let mapped = RustMapping.event(event.pointee) else { return }
            post(mapped)
        }
    }

    private func post(_ event: RemotePlaySession.Event) {
        let handler = eventHandler
        DispatchQueue.main.async { MainActor.assumeIsolated { handler(event) } }
    }
}
