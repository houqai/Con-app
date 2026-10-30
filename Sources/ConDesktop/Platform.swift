import CConDesktop
import CSDL2
import Foundation
import SoleCloud
import SoleCore
import SoleEngine
import SoleLogic

struct DesktopCredentials: CredentialStore {
    static var refusal: CredentialStoreFailure { CredentialStoreFailure(loc("The system keyring could not be used.")) }

    func read(_ account: String) async throws -> Data? { try Self.read(account) }
    func write(_ data: Data, account: String) async throws { try Self.write(data, account) }
    func remove(_ account: String) async throws { try Self.remove(account) }

    static func read(_ account: String) throws -> Data? {
        var length: Int32 = 0, failed: Int32 = 0
        let bytes = con_secret_lookup(account, &length, &failed)
        defer { free(bytes) }
        guard failed == 0 else { throw refusal }
        return bytes.map { Data(bytes: $0, count: Int(length)) }
    }
    static func write(_ data: Data, _ account: String) throws {
        let status = data.withUnsafeBytes { con_secret_store(account, $0.bindMemory(to: UInt8.self).baseAddress, Int32($0.count)) }
        guard status == 0 else { throw refusal }
    }
    static func remove(_ account: String) throws {
        guard con_secret_clear(account) == 0 else { throw refusal }
    }
}

@MainActor final class DesktopLoginPage: SonyLoginPage {
    private var process: Process?
    private var attempt = 0
    private var continuation: CheckedContinuation<SonyLogin, Error>?

    func signIn(url: URL, state: String) async throws -> SonyLogin {
        guard continuation == nil, url.scheme == "https", url.host == "ca.account.sony.com" else { throw PSNAuthorization.AuthError.unavailable }
        let helper = Program.folder.appendingPathComponent(Program.windows ? "con-login.exe" : "con-login")
        let process = Process(), output = Pipe()
        process.executableURL = helper
        process.arguments = [url.absoluteString, PSNCallback.scheme]
        process.standardOutput = output
        let reading = PipeReading()
        attempt += 1
        let mine = attempt
        return try await withCheckedThrowingContinuation { pending in
            continuation = pending
            self.process = process
            process.terminationHandler = { [weak self] ended in
                let lines = String(decoding: reading.wait(), as: UTF8.self).components(separatedBy: "\n")
                let status = ended.terminationStatus, crashed = ended.terminationReason == .uncaughtSignal
                Task { @MainActor in self?.ended(mine, lines, state: state, status: status, crashed: crashed, program: helper.path) }
            }
            do {
                try process.run()
                Thread.detachNewThread { reading.read(output.fileHandleForReading) }
            } catch { self.process = nil; finish(.failure(PSNAuthorization.AuthError.unavailable)) }
        }
    }

    func cancel() {
        finish(.failure(PSNAuthorization.AuthError.cancelled))
        if process?.isRunning == true { process?.terminate() }
        process = nil
    }

    private func ended(_ mine: Int, _ lines: [String], state: String, status: Int32, crashed: Bool, program: String) {
        guard mine == attempt, process != nil else { return }
        process = nil
        if status == 3 {
            let reason = Program.windows
                ? loc("The sign-in window did not open: this computer has no Microsoft Edge WebView2. Install it from Microsoft's website and try again.")
                : loc("The sign-in window did not open: Ubuntu gives it no sandbox for Sony's page. Run this once in a terminal: %@", "sudo \(URL(fileURLWithPath: program).deletingLastPathComponent().path)/install-apparmor.sh")
            finish(.failure(PSNAuthorization.AuthError.pageRefused(reason)))
            return
        }
        if crashed || status > 1 { finish(.failure(PSNAuthorization.AuthError.unavailable)); return }
        guard lines.count >= 3, let url = URL(string: lines[0]), !lines[0].isEmpty else { finish(.failure(PSNAuthorization.AuthError.cancelled)); return }
        do {
            let code = try PSNCallback.code(from: url, expectedState: state)
            finish(.success(SonyLogin(code: code, sso: SonySSO.credential(sentSecurely: lines[1], sentPlainly: lines[2]))))
        } catch let failure as PSNCallback.Failure {
            finish(.failure(PSNAuthorization.AuthError.callback(failure)))
        } catch {
            finish(.failure(PSNAuthorization.AuthError.invalidCallback))
        }
    }

    private func finish(_ result: Result<SonyLogin, Error>) {
        guard let pending = continuation else { return }
        continuation = nil
        pending.resume(with: result)
    }
}

private final class PipeReading: @unchecked Sendable {
    private var data = Data()
    private let done = DispatchSemaphore(value: 0)
    func read(_ handle: FileHandle) { data = handle.readDataToEndOfFile(); done.signal() }
    func wait() -> Data { done.wait(); return data }
}

final class DesktopMedia: StreamMedia, @unchecked Sendable {
    var requestKeyframe: (@Sendable () -> Void)?
    private let hevc: Bool
    private let lock = NSLock()
    private var stream: VideoStream
    private var gate: LossGate
    private let figures = VideoCounters()
    private var active = true
    private var open = false
    private var keyframeAsked = 0.0
    private var sound: SDL_AudioDeviceID = 0
    private var soundFormat: (channels: Int, rate: Int)?
    private var soundPieces = 0, loudPieces = 0, leftOut = 0
    private var clock = PresentationClock(lead: 0)
    private var cadence = PictureCadence()
    private var cadenceLog = CadenceLog(directory: Diagnostics.directory)
    private var afterHidden = false
    private var generationWanted = false, generationRoom = false
    private var lastGenerated: Int32 = 0
    static let generationRefresh = 100

    init(hevc: Bool) {
        self.hevc = hevc
        stream = VideoStream(codec: hevc ? .h265 : .h264)
        gate = LossGate()
    }

    func video(_ buffer: UnsafeBufferPointer<UInt8>, frame: Int32, display: Bool) -> Bool {
        let arrival = DispatchTime.now().uptimeNanoseconds
        lock.lock(); defer { lock.unlock() }
        guard active, let bytes = buffer.baseAddress else { return true }
        let unit = stream.read(buffer)
        figures.update { $0.receivedFrames += 1; $0.bytes += buffer.count; if unit.isKeyframe { $0.keyframes += 1 } }
        if !open {
            open = con_video_open(hevc ? 1 : 0) == 0
            if open { gate.restart() }
        }
        guard open else { return unit.hasPicture ? lost() : true }
        let index = frame >= 0 ? Int(frame) : nil
        let decision = gate.take(unit, of: stream, frame: index)
        figures.update { $0.missingFrames += gate.missing }
        guard decision == .decode else { return lost() }
        let show: Int32 = display ? 1 : 0
        var change = -1.0
        let taken = gate.parametersFirst.isEmpty
            ? con_video_submit(bytes, Int32(buffer.count), show, &change)
            : (gate.parametersFirst.flatMap { [0, 0, 0, 1] + $0 } + buffer).withUnsafeBufferPointer { con_video_submit($0.baseAddress, Int32($0.count), show, &change) }
        if taken > 0, unit.hasPicture, !display {
            afterHidden = true
            figures.update { $0.hiddenFrames += 1 }
            if clock.lead > 0 { _ = clock.timestamp(arrival: arrival, frame: index, isNew: false) }
        } else if change >= 0 {
            let discontinuity = gate.missing > 0 || afterHidden
            afterHidden = false
            if discontinuity { cadence = PictureCadence() }
            let isNew = discontinuity || cadence.isNew(change: change)
            cadenceLog.add(change: change, new: isNew)
            var due: Int64 = 0
            if clock.lead > 0 {
                let time = clock.timestamp(arrival: arrival, frame: index, isNew: isNew)
                due = (Int64(time) - Int64(DispatchTime.now().uptimeNanoseconds)) / 1000
            }
            con_video_present(isNew ? 1 : 0, due)
            figures.update { if isNew { $0.newFrames += 1 }; $0.lastChange = change }
        }
        if taken < 0 { open = false }
        gate.decoded(taken > 0)
        guard taken > 0 || !unit.hasPicture else { return lost() }
        return true
    }

    private func lost() -> Bool {
        figures.update { $0.decodeFailures += 1 }
        let now = ProcessInfo.processInfo.systemUptime
        if now - keyframeAsked > 2 { keyframeAsked = now; requestKeyframe?() }
        return false
    }

    func audio(_ samples: UnsafeBufferPointer<Int16>, channels: Int, rate: Int) {
        lock.lock(); defer { lock.unlock() }
        guard active, channels > 0, let base = samples.baseAddress else { return }
        if soundFormat.map({ $0 != (channels, rate) }) ?? true {
            if sound != 0 { SDL_CloseAudioDevice(sound) }
            var wanted = SDL_AudioSpec(), got = SDL_AudioSpec()
            wanted.freq = Int32(rate); wanted.format = SDL_AudioFormat(AUDIO_S16SYS); wanted.channels = UInt8(channels); wanted.samples = 512
            sound = SDL_OpenAudioDevice(nil, 0, &wanted, &got, 0)
            soundFormat = (channels, rate)
            if sound != 0 { SDL_PauseAudioDevice(sound, 0) }
        }
        guard sound != 0 else { return }
        soundPieces += 1
        if samples.contains(where: { $0 > 64 || $0 < -64 }) { loudPieces += 1 }
        let bytesPerSecond = rate * channels * 2
        guard Int(SDL_GetQueuedAudioSize(sound)) < bytesPerSecond / 5 else { leftOut += 1; return }
        SDL_QueueAudio(sound, base, UInt32(samples.count * 2))
    }

    func counters() -> StreamMeter.Reading {
        var reading = StreamMeter.Reading()
        var decoded: Int32 = 0, drawn: Int32 = 0, skipped: Int32 = 0, generated: Int32 = 0, width: Int32 = 0, height: Int32 = 0, decodeTime: Int32 = 0, interval: Int32 = 0
        con_video_counts(&decoded, &drawn, &skipped, &generated, &width, &height, &decodeTime, &interval)
        let hevc = hevc
        lock.lock()
        let made = generated > lastGenerated
        lastGenerated = generated
        let generation: GenerationState = !generationWanted ? .off : con_video_generation_available() == 0 ? .unavailable
            : !generationRoom ? .standby : made ? .active : .preparing
        lock.unlock()
        reading.video = figures.update {
            $0.shownFrames = max(0, Int(drawn) - Int(generated)); $0.queueDrops = Int(skipped)
            $0.generatedFrames = Int(generated); $0.generation = generation
            $0.upscaledHeight = Int(con_video_upscaled_height())
            $0.addedDelayMs = generation == .active ? Double(interval) / 2000 : 0
            $0.width = Int(width); $0.height = Int(height); $0.hardwareDecoder = con_video_hardware() != 0
            $0.decodeMs = Double(decodeTime) / 1000
            $0.codec = hevc ? 0x68766331 : 0x61766331
            return $0
        }
        lock.lock(); let pieces = soundPieces, loud = loudPieces, out = leftOut; lock.unlock()
        reading.audioReceived = pieces; reading.audioNonSilent = loud; reading.audioPlayed = pieces - out; reading.audioErrors = out
        reading.askedHEVC = hevc
        return reading
    }

    func show(_ picture: StreamPicture) {
        let byRefresh = picture.presentationLeadMs == Smoothness.byRefresh
        con_video_pacing(byRefresh ? 1 : 0)
        con_video_upscale(picture.upscaling ? Int32(picture.upscaleAmount.factor * 100) : 0)
        con_video_upscale_method(picture.upscaleMethod == .nis ? 1 : picture.upscaleMethod == .anime4k ? 2 : 0)
        let room = picture.displayHz >= Self.generationRefresh
        con_video_generation(picture.frameGeneration && room ? 1 : 0)
        lock.lock()
        clock.lead = Double(Smoothness.lead(picture.presentationLeadMs)) * 1_000_000
        generationWanted = picture.frameGeneration; generationRoom = room
        lock.unlock()
    }

    func close() {
        lock.lock()
        active = false
        if sound != 0 { SDL_CloseAudioDevice(sound); sound = 0 }
        lock.unlock()
        con_video_close()
    }
}

@MainActor final class DesktopStreamDevice: StreamDevice {
    var onFullScreen: (() -> Void)?
    var rumble: ((UInt16, UInt16, UInt32) -> Void)?
    var effects: (([UInt8]) -> Bool)?

    func openMedia(hevc: Bool) -> StreamMedia { DesktopMedia(hevc: hevc) }
    func clearPicture() { con_video_forget() }
    func stopSound() {}
    var upscaleMethods: [Upscale.Method] = []
    var upscalingSupported: Bool { !upscaleMethods.isEmpty }
    var generationSupported: Bool { con_video_generation_available() != 0 }
    var displayIndex: () -> Int32 = { 0 }
    var displayHz: Int {
        var mode = SDL_DisplayMode()
        return SDL_GetCurrentDisplayMode(displayIndex(), &mode) == 0 ? Int(mode.refresh_rate) : 0
    }
    var fillsWindow = false
    func toggleFullScreen() { onFullScreen?() }
    func keepAwake(_ on: Bool) { if on { SDL_DisableScreenSaver() } else { SDL_EnableScreenSaver() } }

    private var deliver: ((ControllerState?) -> Void)?
    private var pad: PadReading?
    private var keys = KeyboardPlay()
    func startInput(deliver: @escaping (ControllerState?) -> Void) {
        self.deliver = deliver
        keys.begin(layout: KeyboardLayout.stored(in: Settings.store))
        deliver(ControllerState())
    }
    func stopInput() { releaseMouse(); deliver = nil; keys.releaseKeys() }
    func take(_ reading: PadReading?) {
        pad = reading
        if reading == nil { keys.releaseKeys() }
        send(reading == nil)
    }
    func key(_ code: UInt16, down: Bool) {
        if code == Key.leftSystem || code == Key.rightSystem { if down { releaseMouse() }; return }
        if !keys.key(code, down: down) { keys.modifier(code, down: down) }
        send(false)
    }
    private func send(_ letGo: Bool, tick: Bool = false) {
        guard let deliver else { return }
        if letGo && pad == nil { deliver(nil); return }
        var state = ControllerState()
        state.merge(keys.sample(tick: tick, bumpers: keys.mouseCaptured && mouse.bumpers), pad: pad ?? PadReading())
        deliver(state)
    }

    static var systemKeyName: String { Program.windows ? "Win" : "Super" }
    private var mouse = MouseSettings(defaults: Settings.store)
    private var lastTick = 0.0
    var mouseCaptured: Bool { keys.mouseCaptured }

    @discardableResult func captureMouse() -> Bool {
        guard deliver != nil, !keys.mouseCaptured else { return false }
        mouse = MouseSettings(defaults: Settings.store)
        guard mouse.enabled else { return false }
        keys.captureMouse(sensitivity: mouse.sensitivity)
        SDL_SetRelativeMouseMode(SDL_TRUE)
        lastTick = ProcessInfo.processInfo.systemUptime
        return true
    }
    func releaseMouse() {
        guard keys.releaseMouse() else { return }
        SDL_SetRelativeMouseMode(SDL_FALSE)
        send(false)
    }
    func mouseMoved(dx: Double, dy: Double) {
        guard keys.mouseCaptured else { return }
        _ = keys.mouse(.moved(dx: dx, dy: dy))
    }
    func mouseButton(left: Bool, down: Bool) {
        guard keys.mouseCaptured else { return }
        if keys.mouse(left ? (down ? .leftDown : .leftUp) : (down ? .rightDown : .rightUp)) { send(false) }
    }
    func tickMouse() {
        guard keys.mouseCaptured, deliver != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime, interval = 0.008
        var ticks = Int((now - lastTick) / interval)
        guard ticks > 0 else { return }
        if ticks > 4 { ticks = 4; lastTick = now } else { lastTick += Double(ticks) * interval }
        for _ in 0..<ticks { send(false, tick: true) }
    }
    func resetMotion() {}
    func releasePointer() { releaseMouse() }

    private let actuators = DualSenseActuators()
    func beginFeedback() { actuators.start() }
    func feedback(_ report: DualSenseReport) {
        if effects?(report.effects) == true { return }
        guard report.selectsRumble else { return }
        rumble?(UInt16(report.effects[3]) * 2 * 257, UInt16(report.effects[2]) * 2 * 257, 5000)
    }
    func haptics(_ pcm: Data) {
        if actuators.play(pcm) { playedHaptics += 1; return }
        guard let motors = HapticsSound.motors(pcm) else { return }
        rumble?(UInt16(motors.left * 65535), UInt16(motors.right * 65535), 120)
        playedHaptics += 1
    }
    private(set) var playedHaptics = 0
    func effectIntensity(trigger: Bool, value: UInt32) {}
    func silenceFeedback() { rumble?(0, 0, 0); actuators.silence() }

    func loadConsoles() -> [RegisteredConsole] {
        guard let stored = try? DesktopCredentials.read("consoles") else { return [] }
        return (try? JSONDecoder().decode([RegisteredConsole].self, from: stored)) ?? []
    }
    func saveConsoles(_ consoles: [RegisteredConsole]) -> Bool {
        guard let data = try? JSONEncoder().encode(consoles) else { return false }
        return (try? DesktopCredentials.write(data, "consoles")) != nil
    }
}

@MainActor final class DualSenseActuators {
    private var device: SDL_AudioDeviceID = 0
    private var nextLook = 0.0
    private static let most = 48_000 * 4 * 4 / 16

    func start() { nextLook = 0; _ = open() }

    private func open() -> Bool {
        if device != 0 { return true }
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= nextLook else { return false }
        nextLook = now + 2
        for index in 0..<SDL_GetNumAudioDevices(0) {
            guard let name = SDL_GetAudioDeviceName(index, 0).map({ String(cString: $0) }), name.localizedCaseInsensitiveContains("DualSense") || name.localizedCaseInsensitiveContains("Wireless Controller") else { continue }
            var native = SDL_AudioSpec()
            guard SDL_GetAudioDeviceSpec(index, 0, &native) == 0, native.channels == 4 else { continue }
            var wanted = SDL_AudioSpec(), got = SDL_AudioSpec()
            wanted.freq = Int32(HapticsSound.rate); wanted.format = SDL_AudioFormat(AUDIO_F32SYS); wanted.channels = 4; wanted.samples = 256
            device = SDL_OpenAudioDevice(name, 0, &wanted, &got, 0)
            if device != 0 { SDL_PauseAudioDevice(device, 0); return true }
        }
        return false
    }

    func play(_ pcm: Data) -> Bool {
        guard open(), let actuators = HapticsSound.actuators(pcm) else { return false }
        if SDL_GetAudioDeviceStatus(device) != SDL_AUDIO_PLAYING {
            SDL_CloseAudioDevice(device); device = 0
            return false
        }
        if Int(SDL_GetQueuedAudioSize(device)) > Self.most { SDL_ClearQueuedAudio(device) }
        var frames = [Float](repeating: 0, count: actuators.left.count * 4)
        for index in 0..<actuators.left.count {
            frames[index * 4 + 2] = actuators.left[index]
            frames[index * 4 + 3] = actuators.right[index]
        }
        frames.withUnsafeBytes { _ = SDL_QueueAudio(device, $0.baseAddress, UInt32($0.count)) }
        return true
    }

    func silence() { if device != 0 { SDL_ClearQueuedAudio(device) } }
}
