import Foundation
import SoleCore
import SoleEngine

public struct RegisteredConsole: Codable, Identifiable, Hashable, Sendable {
    public let hostID: String
    public var name: String
    public var isPS5: Bool
    public var credentials: RemotePlayCredentials
    public var id: String { hostID }
    public init(hostID: String, name: String, isPS5: Bool, credentials: RemotePlayCredentials) {
        self.hostID = hostID; self.name = name; self.isPS5 = isPS5; self.credentials = credentials
    }
}

public struct StreamPicture: Equatable, Sendable {
    public var frameGeneration: Bool
    public var presentationLeadMs: Int
    public var generationHeight: Int
    public var displayHz: Int
    public var upscaling: Bool
    public var upscaleMethod: Upscale.Method
    public var upscaleAmount: Upscale.Amount
    public init(frameGeneration: Bool, presentationLeadMs: Int, generationHeight: Int, displayHz: Int, upscaling: Bool = false, upscaleMethod: Upscale.Method = .fsr, upscaleAmount: Upscale.Amount = .double) {
        self.frameGeneration = frameGeneration; self.presentationLeadMs = presentationLeadMs
        self.generationHeight = generationHeight; self.displayHz = displayHz; self.upscaling = upscaling; self.upscaleMethod = upscaleMethod
        self.upscaleAmount = upscaleAmount
    }
}

public enum Smoothness {
    public static let key = "sole.presentationLead"
    public static let levels = [0, 4, 8, 12, 16, 21]
    public static let standard = 21
    public static let byRefresh = -1
    public static func read(_ defaults: UserDefaults) -> Int {
        if defaults.object(forKey: key) != nil {
            let kept = defaults.integer(forKey: key)
            return kept == byRefresh ? byRefresh : nearest(kept)
        }
        if defaults.object(forKey: StreamModel.evenPresentationKey) != nil, !defaults.bool(forKey: StreamModel.evenPresentationKey) { return 0 }
        return standard
    }
    public static func nearest(_ ms: Int) -> Int { levels.min { abs($0 - ms) < abs($1 - ms) } ?? standard }
    public static func title(_ ms: Int) -> String {
        ms == byRefresh ? loc("By screen refreshes") : ms == 0 ? loc("Disabled") : ms == standard ? loc("+%@ ms · smoothest", ms) : loc("+%@ ms", ms)
    }
    public static func choices(byRefresh offered: Bool) -> [(Int, String)] {
        ([0] + (offered ? [byRefresh] : []) + levels.dropFirst()).map { ($0, title($0)) }
    }
    public static func lead(_ choice: Int) -> Int { max(0, choice) }
}

public protocol StreamMedia: AnyObject, Sendable {
    func video(_ buffer: UnsafeBufferPointer<UInt8>, frame: Int32, display: Bool) -> Bool
    func audio(_ samples: UnsafeBufferPointer<Int16>, channels: Int, rate: Int)
    var requestKeyframe: (@Sendable () -> Void)? { get set }
    func counters() -> StreamMeter.Reading
    func show(_ picture: StreamPicture)
    func close()
}

@MainActor public protocol StreamDevice: AnyObject {
    func openMedia(hevc: Bool) -> StreamMedia
    func clearPicture()
    func stopSound()
    var generationSupported: Bool { get }
    var upscalingSupported: Bool { get }
    var upscaleMethods: [Upscale.Method] { get }
    var displayHz: Int { get }
    var fillsWindow: Bool { get set }
    func toggleFullScreen()
    var leavesFullScreen: Bool { get }
    func keepAwake(_ on: Bool)

    func startInput(deliver: @escaping @Sendable (ControllerState?) -> Void)
    func stopInput()
    func resetMotion()
    func releasePointer()

    func beginFeedback()
    func feedback(_ report: DualSenseReport)
    func haptics(_ pcm: Data)
    func effectIntensity(trigger: Bool, value: UInt32)
    func silenceFeedback()
    var playedHaptics: Int { get }

    func loadConsoles() -> [RegisteredConsole]
    func saveConsoles(_ consoles: [RegisteredConsole]) -> Bool
}

public extension StreamDevice {
    var leavesFullScreen: Bool { true }
    var upscalingSupported: Bool { false }
    var upscaleMethods: [Upscale.Method] { [.fsr] }
}

@MainActor open class StreamModel: StreamPlayer {
    public typealias Phase = StreamPhase
    public var willChange: (() -> Void)?
    private func changing() { willChange?() }

    private let device: StreamDevice
    private let defaults: UserDefaults

    public init(device: StreamDevice, defaults: UserDefaults = .standard) {
        self.device = device
        self.defaults = defaults
        registered = device.loadConsoles()
    }

    public private(set) var consoles: [DiscoveredConsole] = [] { willSet { changing() } }
    public private(set) var registered: [RegisteredConsole] { willSet { changing() } }
    public private(set) var phase: Phase = .idle {
        willSet { changing() }
        didSet { device.keepAwake(phase.isLive); let cloud = phase.isCloud; inputLock.withLock { inputCloud = cloud } }
    }
    public var hasControls: Bool { phase.isLive }
    public var offlineRegistered: [RegisteredConsole] {
        registered.filter { entry in !consoles.contains { $0.id == entry.hostID } }
    }
    public private(set) var statusText: String? { willSet { changing() } }
    public var loginPINRequest = false { willSet { changing() } }
    public private(set) var stats: StreamStats? { willSet { changing() } }
    public private(set) var streamGame: StreamGame? { willSet { changing() } }

    public nonisolated static let statsKey = "sole.streamStats"
    public nonisolated static let frameGenerationKey = "sole.frameGeneration"
    public nonisolated static let generationHeightKey = "sole.generationHeight"
    public nonisolated static let evenPresentationKey = "sole.evenPresentation"
    public var statsVisible: Bool {
        get { defaults.bool(forKey: Self.statsKey) }
        set { changing(); defaults.set(newValue, forKey: Self.statsKey) }
    }
    public var frameGeneration: Bool {
        get { defaults.bool(forKey: Self.frameGenerationKey) }
        set { changing(); defaults.set(newValue, forKey: Self.frameGenerationKey) }
    }
    public var frameGenerationSupported: Bool { device.generationSupported }
    public nonisolated static let upscalingKey = "sole.upscaling"
    public var upscaling: Bool {
        get { defaults.bool(forKey: Self.upscalingKey) }
        set { changing(); defaults.set(newValue, forKey: Self.upscalingKey) }
    }
    public var upscaleAmount: Upscale.Amount {
        get { Upscale.Amount.stored(defaults.string(forKey: Upscale.amountKey)) }
        set { changing(); defaults.set(newValue.rawValue, forKey: Upscale.amountKey) }
    }
    public var upscaleMethod: Upscale.Method {
        get { defaults.string(forKey: Upscale.methodKey).flatMap(Upscale.Method.init(rawValue:)) ?? .fsr }
        set { changing(); defaults.set(newValue.rawValue, forKey: Upscale.methodKey) }
    }
    private var picture: StreamPicture {
        StreamPicture(frameGeneration: frameGeneration,
                      presentationLeadMs: Smoothness.read(defaults),
                      generationHeight: defaults.object(forKey: Self.generationHeightKey) == nil ? GenerationState.defaultHeight : defaults.integer(forKey: Self.generationHeightKey),
                      displayHz: device.displayHz,
                      upscaling: upscaling,
                      upscaleMethod: upscaleMethod.used(in: device.upscaleMethods),
                      upscaleAmount: upscaleAmount)
    }
    public var vibration = true { didSet { if oldValue, !vibration { device.silenceFeedback() } } }
    public var fillsWindow: Bool {
        get { device.fillsWindow }
        set { device.fillsWindow = newValue }
    }
    public var capturesVideo: Bool {
        VideoCaptureChoice.resolve(environment: ProcessInfo.processInfo.environment, setting: defaults.bool(forKey: VideoCaptureChoice.settingKey))
    }
    nonisolated static func freshVideoCapture(in directory: URL?) -> String? {
        guard let directory else { return nil }
        let file = directory.appendingPathComponent(VideoCaptureChoice.fileName)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        } catch { return nil }
        return file.path
    }
    private func videoCapturePath() -> String? {
        guard capturesVideo else { return nil }
        let path = Self.freshVideoCapture(in: Diagnostics.directory)
        Self.connectionDiagnostic(path == nil ? "video capture failed to prepare" : "video capture=\(VideoCaptureChoice.fileName)")
        return path
    }

    private var discovery: ConsoleDiscovery?
    public var accountProvider: (() async throws -> [UInt8])?

    public func isRegistered(_ hostID: String) -> Bool { registered.contains { $0.hostID == hostID } }

    public func startDiscovery() {
        guard discovery == nil else { return }
        let discovery = ConsoleDiscovery { [weak self] consoles in
            self?.consoles = consoles.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        discovery.start()
        self.discovery = discovery
    }
    public func stopDiscovery() {
        discovery?.stop()
        discovery = nil
        consoles = []
    }

    public func register(console: DiscoveredConsole, pin: String) async {
        guard let accountProvider, let pinValue = StreamText.registrationPIN(pin) else {
            phase = .failed(loc("Enter the 8-digit registration code from the console."))
            return
        }
        phase = .registering(hostID: console.id)
        statusText = loc("Registering %@…", console.name)
        do {
            let account = try await accountProvider()
            let registration = RemotePlayRegistration()
            let credentials = try await registration.register(host: console.address, targetValue: console.targetValue, psnAccountID: account, pin: pinValue)
            guard remember(RegisteredConsole(hostID: console.id, name: console.name, isPS5: console.isPS5, credentials: credentials)) else {
                phase = .failed(loc("The console is registered, but the registration could not be saved: after Con restarts it will have to be registered again."))
                statusText = nil
                return
            }
            phase = .idle
            statusText = loc("%@ is registered. You can connect now.", console.name)
        } catch {
            phase = .failed(StreamText.describe(error))
            statusText = nil
        }
    }
    @discardableResult func remember(_ console: RegisteredConsole) -> Bool {
        registered = registered.filter { $0.hostID != console.hostID } + [console]
        return device.saveConsoles(registered)
    }
    public func removeRegistration(hostID: String) {
        registered = registered.filter { $0.hostID != hostID }
        if !device.saveConsoles(registered) { phase = .failed(loc("Could not remove the registration: the console will appear again after Con restarts.")) }
    }
    public func clearFailure() { if case .failed = phase { phase = .idle } }

    private var media: StreamMedia?
    private var session: RemotePlaySession? { didSet { let session = session; inputLock.withLock { inputSession = session } } }
    private var connectionAttempt = UUID()
    private var hapticPackets = 0
    private var triggerPackets = 0
    private var meter = StreamMeter()
    public var cloudEnded: ((String?) -> Void)?
    public var cloudRestart: (() -> Void)?
    public private(set) var silentSound = false { willSet { changing() } }
    private var silentWatch = SilentSoundWatch()
    public private(set) var trophyNotice: TrophyNotice? { willSet { changing() } }
    private static let trophySeconds: UInt64 = 6
    private var trophyQueue: [TrophyNotice] = []
    private var trophyTask: Task<Void, Never>?
    public func showTrophy(_ notice: TrophyNotice) {
        guard phase.isLive else { return }
        trophyQueue.append(notice)
        guard trophyTask == nil else { return }
        trophyTask = Task { [weak self] in
            while let next = self?.nextTrophy() {
                self?.trophyNotice = next
                try? await Task.sleep(nanoseconds: Self.trophySeconds * 1_000_000_000)
                guard !Task.isCancelled else { return }
            }
            self?.trophyNotice = nil; self?.trophyTask = nil
        }
    }
    private func nextTrophy() -> TrophyNotice? { trophyQueue.isEmpty ? nil : trophyQueue.removeFirst() }
    private func clearTrophies() { trophyTask?.cancel(); trophyTask = nil; trophyQueue = []; trophyNotice = nil }

    public func connect(console: DiscoveredConsole) async {
        guard let entry = registered.first(where: { $0.hostID == console.id }) else {
            phase = .failed(loc("The console is not registered."))
            return
        }
        disconnect()
        device.beginFeedback()
        hapticPackets = 0; triggerPackets = 0
        meter = StreamMeter()
        let attempt = UUID(); connectionAttempt = attempt
        phase = .connecting(hostID: console.id)
        statusText = loc("Connecting to %@…", console.name)
        device.clearPicture()
        do {
            guard !Task.isCancelled else { return }
            let hostID = console.id
            let media = device.openMedia(hevc: false)
            self.media = media
            let session = try RemotePlaySession(
                host: console.address,
                credentials: entry.credentials,
                profile: .init(resolution: 1080, fps: 60),
                videoCapturePath: videoCapturePath(),
                logSink: { StreamModel.mediaLog($0) },
                onVideo: { buffer, frame, _, _, display in media.video(buffer, frame: frame, display: display) },
                onAudio: { samples, channels, rate in media.audio(samples, channels: channels, rate: rate) },
                onEvent: { [weak self] event in
                    guard let self, self.connectionAttempt == attempt else { return }
                    self.handle(event, hostID: hostID, name: console.name)
                }
            )
            media.requestKeyframe = { [weak session] in session?.requestKeyframe() }
            self.session = session
            Self.connectionDiagnostic(Self.engineLine)
            try session.start()
        } catch {
            guard connectionAttempt == attempt else { return }
            media?.close(); media = nil
            device.stopSound()
            phase = .failed(StreamText.describe(error))
            statusText = nil
            session = nil
        }
    }

    public func connectCloud(_ stream: CloudStream) {
        let slot = stream.slot, title = stream.title
        disconnect()
        streamGame = stream.game
        device.beginFeedback()
        hapticPackets = 0; triggerPackets = 0
        silentWatch = SilentSoundWatch(); silentSound = false; inputLock.withLock { inputRestart = false }
        meter = StreamMeter(server: stream.server, measuredPingMs: stream.measuredPingMs, reportedPingMs: stream.reportedPingMs)
        let attempt = UUID(); connectionAttempt = attempt
        phase = .connecting(hostID: Phase.cloudHostID)
        statusText = loc("Connecting the video stream of %@…", title)
        device.clearPicture()
        let media = device.openMedia(hevc: slot.isPS5)
        self.media = media
        do {
            let session = try RemotePlaySession(
                cloud: slot,
                profile: .init(resolution: stream.resolution, fps: 60),
                videoCapturePath: videoCapturePath(),
                logSink: { StreamModel.mediaLog($0) },
                onVideo: { buffer, frame, _, _, display in media.video(buffer, frame: frame, display: display) },
                onAudio: { samples, channels, rate in media.audio(samples, channels: channels, rate: rate) },
                onEvent: { [weak self] event in
                    guard let self, self.connectionAttempt == attempt else { return }
                    self.handle(event, hostID: Phase.cloudHostID, name: title)
                }
            )
            media.requestKeyframe = { [weak session] in session?.requestKeyframe() }
            self.session = session
            Self.connectionDiagnostic(Self.engineLine)
            try session.start()
        } catch {
            self.media?.close(); self.media = nil
            device.stopSound()
            phase = .idle
            statusText = nil
            session = nil
            cloudEnded?(StreamText.describe(error))
        }
    }

    public func disconnect() {
        let wasCloud = phase.isCloud
        defer { if wasCloud { cloudEnded?(nil) } }
        connectionAttempt = UUID()
        media?.close(); media = nil
        stopInput()
        let previous = session
        session = nil
        Task.detached { previous?.stop() }
        device.stopSound()
        device.clearPicture()
        if phase.isLive { phase = .idle }
        statusText = nil
        loginPINRequest = false
        streamGame = nil
        clearTrophies()
    }
    public func shutDown() { session?.stop() }

    public func submitLoginPIN(_ pin: String) {
        session?.submitLoginPIN(pin.filter(\.isNumber))
        loginPINRequest = false
    }

    func handle(_ event: RemotePlaySession.Event, hostID: String, name: String) {
        switch event {
        case .motionReset: device.resetMotion()
        case .effectIntensity(let trigger, let value): device.effectIntensity(trigger: trigger, value: value)
        case .rumble, .triggerEffects, .led, .playerIndex:
            if case .triggerEffects = event { triggerPackets += 1 }
            if !vibration, event.isVibration { break }
            if let report = DualSenseReport(event) { device.feedback(report) }
        case .haptics(let pcm):
            hapticPackets += 1
            if vibration { device.haptics(pcm) }
        case .connected:
            phase = .streaming(hostID: hostID)
            statusText = loc("Streaming %@.", name)
            let offered = menuCapabilities
            inputLock.withLock { inputGeneration = offered.generation; inputUpscaler = offered.upscaler; inputUpscaleMethod = offered.upscaleMethod; inputFullScreen = offered.fullScreen }
            device.startInput { @Sendable [weak self] reading in self?.take(reading) }
            startStats()
        case .loginPINRequired:
            loginPINRequest = true
            statusText = loc("The console is asking for a login code.")
        case .quit(let reason, let isError, let stage):
            Self.connectionDiagnostic(Self.quitLine(reason: reason, isError: isError, stage: stage))
            media?.close(); media = nil
            device.stopSound()
            stopInput()
            session = nil
            clearTrophies()
            if hostID == Phase.cloudHostID {
                phase = .idle; statusText = nil; loginPINRequest = false
                cloudEnded?(isError ? StreamText.quitReason(reason) : nil)
                return
            }
            let end = StreamText.ended(reason: StreamText.quitReason(reason), isError: isError)
            phase = end.failure.map(Phase.failed) ?? .idle
            statusText = end.status
            loginPINRequest = false
        }
    }

    public private(set) var menu = StreamMenu() { willSet { changing() } }
    private var menuCapabilities: (generation: Bool, upscaler: Bool, upscaleMethod: Bool, fullScreen: Bool) {
        (frameGenerationSupported, device.upscalingSupported, device.upscaleMethods.count > 1, device.leavesFullScreen)
    }
    private let inputLock = NSLock()
    nonisolated(unsafe) private var controls = StreamControls()
    nonisolated(unsafe) private var inputSession: RemotePlaySession?
    nonisolated(unsafe) private var inputCloud = false
    nonisolated(unsafe) private var inputGeneration = false
    nonisolated(unsafe) private var inputUpscaler = false
    nonisolated(unsafe) private var inputUpscaleMethod = false
    nonisolated(unsafe) private var inputFullScreen = true
    nonisolated(unsafe) private var inputRestart = false
    nonisolated(unsafe) private var shownMenu = StreamMenu()
    private func publishMenu() {
        let current = inputLock.withLock { () -> StreamMenu in shownMenu = controls.menu; return controls.menu }
        if menu != current { menu = current }
    }

    private func stopInput() {
        session?.setControllerState(.idle)
        inputLock.withLock { controls.reset() }; publishMenu()
        device.stopInput()
        statsTask?.cancel(); statsTask = nil
        stats = nil
    }

    nonisolated func take(_ reading: ControllerState?) {
        inputLock.lock()
        guard let session = inputSession else { inputLock.unlock(); return }
        guard let reading else { inputLock.unlock(); session.setControllerState(.idle); return }
        guard inputCloud else { inputLock.unlock(); session.setControllerState(reading); return }
        let buttons = ControllerState.Button(rawValue: reading.raw.buttons)
        let outcome = controls.take(reading, at: ProcessInfo.processInfo.systemUptime, generation: inputGeneration, upscaler: inputUpscaler, upscaleMethod: inputUpscaleMethod, fullScreen: inputFullScreen, restart: inputRestart)
        let forGame = controls.forGame(reading)
        let menuChanged = controls.menu != shownMenu
        inputLock.unlock()
        session.setControllerState(forGame)
        guard outcome != .none || menuChanged else { return }
        let onScreen: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            switch outcome {
            case .opened: self.device.releasePointer()
            case .chosen(let item): self.choose(item, holding: buttons)
            case .closed, .none: break
            }
            self.publishMenu()
        }
        if Thread.isMainThread { MainActor.assumeIsolated { onScreen() } } else { DispatchQueue.main.async { MainActor.assumeIsolated { onScreen() } } }
    }

    public func choose(_ item: StreamMenu.Item, holding buttons: ControllerState.Button = []) {
        switch item {
        case .restart: closeMenu(holding: buttons); cloudRestart?()
        case .resume: closeMenu(holding: buttons)
        case .stats: statsVisible.toggle()
        case .generation: if frameGenerationSupported { frameGeneration.toggle() }
        case .upscaler: if device.upscalingSupported { upscaling.toggle() }
        case .upscaleAmount: if device.upscalingSupported { upscaleAmount = upscaleAmount.next }
        case .upscaleMethod: if device.upscaleMethods.count > 1 { upscaleMethod = upscaleMethod.used(in: device.upscaleMethods).next(in: device.upscaleMethods) }
        case .fullScreen: device.toggleFullScreen()
        case .leave: closeMenu(holding: buttons); disconnect()
        }
    }
    public func openMenu() {
        guard phase.isCloud else { return }
        let offered = menuCapabilities
        inputLock.withLock { controls.openMenu(generation: offered.generation, upscaler: offered.upscaler, upscaleMethod: offered.upscaleMethod, fullScreen: offered.fullScreen, restart: inputRestart) }; publishMenu()
        device.releasePointer()
    }
    public func closeMenu(holding buttons: ControllerState.Button = []) {
        inputLock.withLock { controls.closeMenu(holding: buttons) }; publishMenu()
    }
    public func pointMenu(at item: StreamMenu.Item) {
        inputLock.withLock { controls.point(at: item) }; publishMenu()
    }

    private var statsTask: Task<Void, Never>?
    private var mediaHealthRecordedAt = Date.distantPast

    private func startStats() {
        guard statsTask == nil else { return }
        sampleStats()
        statsTask = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self else { return }
                self.sampleStats()
            }
        }
    }

    func sampleStats() {
        guard let media, let session else { return }
        let picture = self.picture
        media.show(picture)
        var reading = media.counters()
        reading.hapticPlayed = device.playedHaptics; reading.hapticPackets = hapticPackets; reading.triggerPackets = triggerPackets
        reading.roundTrip = session.roundTrip()
        reading.hidden = session.hiddenPictures().map { (Int(clamping: $0.frames), Int(clamping: $0.runs)) }
        reading.displayHz = picture.displayHz
        let next = meter.sample(reading, at: ProcessInfo.processInfo.systemUptime)
        stats = next
        if phase.isCloud { watchSound(next) }
        let now = Date()
        if phase.isCloud, now.timeIntervalSince(mediaHealthRecordedAt) >= 15 {
            mediaHealthRecordedAt = now
            if let directory = Diagnostics.directory,
               let data = try? JSONSerialization.data(withJSONObject: next.health, options: [.sortedKeys]) {
                DispatchQueue.global(qos: .utility).async {
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try? data.write(to: directory.appendingPathComponent("media-health.json"), options: .atomic)
                }
            }
        }
    }

    private func watchSound(_ stats: StreamStats) {
        switch silentWatch.update(received: stats.audioReceived, heard: stats.audioNonSilent, at: ProcessInfo.processInfo.systemUptime) {
        case .silent:
            Self.connectionDiagnostic("audio: silent for \(Int(SilentSoundWatch.seconds)) s, offering a restart")
            silentSound = true
            inputLock.withLock { inputRestart = true }
            openMenu()
        case .sound:
            Self.connectionDiagnostic("audio: sound is back after the restart offer")
            silentSound = false
            inputLock.withLock { inputRestart = false }
        case .none: break
        }
    }

    nonisolated static var engineLine: String { "engine=rust \(SoleEngine.version)" }

    nonisolated static func quitLine(reason: String, isError: Bool, stage: String?) -> String {
        "quit error=\(isError) reason=\(reason)" + (stage.map { " stage=\($0)" } ?? "")
    }

    nonisolated private static let diagnosticLock = NSLock()

    nonisolated private static func connectionDiagnostic(_ message: String) {
        guard let directory = Diagnostics.directory else { return }
        diagnosticLock.withLock {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("stream-connection.txt")
            let previous = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let line = "\(Date().timeIntervalSince1970) \(message)\n"
            try? Data((String(previous.suffix(8192)) + line).utf8).write(to: url, options: .atomic)
        }
    }

    nonisolated private static func mediaLog(_ message: String) {
        if message.hasPrefix("stream ended:") || message.hasPrefix("transport: ") || message.hasPrefix("audio: ") || message.hasPrefix("audio header:")
            || message == "stream: new stream info, audio restarts" { connectionDiagnostic(message) }
        if StreamText.isConnectionDiagnostic(message) { NSLog("Con engine: %@", NSString(string: message)) }
        if StreamText.isMediaDiagnostic(message) { NSLog("Con media: %@", NSString(string: message)) }
    }
}
