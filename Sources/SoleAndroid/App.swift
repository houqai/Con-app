import CConAndroid
import Foundation
import SoleCloud
import SoleCore
import SoleEngine
import SoleLogic

struct AndroidCredentials: CredentialStore {
    static let refusal = CredentialStoreFailure("Android's protected storage could not be used.")

    func read(_ account: String) async throws -> Data? { try Self.read(account) }
    func write(_ data: Data, account: String) async throws { try Self.write(data, account) }
    func remove(_ account: String) async throws { try Self.remove(account) }

    static func read(_ account: String) throws -> Data? {
        var length: Int32 = 0, failed: Int32 = 0
        let bytes = con_java_store_read(account, &length, &failed)
        defer { free(bytes) }
        guard failed == 0 else { throw refusal }
        return bytes.map { Data(bytes: $0, count: Int(length)) }
    }
    static func write(_ data: Data, _ account: String) throws {
        let status = data.withUnsafeBytes { con_java_store_write(account, $0.bindMemory(to: UInt8.self).baseAddress, Int32($0.count)) }
        guard status == 0 else { throw refusal }
    }
    static func remove(_ account: String) throws {
        guard con_java_store_remove(account) == 0 else { throw refusal }
    }
}

@MainActor final class AndroidLoginPage: SonyLoginPage {
    private var continuation: CheckedContinuation<SonyLogin, Error>?
    private var expectedState = ""
    private var timeout: Task<Void, Never>?

    func signIn(url: URL, state: String) async throws -> SonyLogin {
        guard continuation == nil, url.scheme == "https", url.host == "ca.account.sony.com" else { throw PSNAuthorization.AuthError.unavailable }
        expectedState = state
        timeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 300_000_000_000) } catch { return }
            self?.finish(.failure(PSNAuthorization.AuthError.timedOut))
            con_java_close_login()
        }
        return try await withCheckedThrowingContinuation { pending in
            continuation = pending
            con_java_open_login(url.absoluteString, PSNCallback.scheme)
        }
    }

    func cancel() {
        finish(.failure(PSNAuthorization.AuthError.cancelled))
        con_java_close_login()
    }

    func reached(_ address: String, sentSecurely: String, sentPlainly: String) {
        guard continuation != nil else { return }
        guard let url = URL(string: address) else { finish(.failure(PSNAuthorization.AuthError.invalidCallback)); return }
        do {
            let code = try PSNCallback.code(from: url, expectedState: expectedState)
            finish(.success(SonyLogin(code: code, sso: SonySSO.credential(sentSecurely: sentSecurely, sentPlainly: sentPlainly))))
        } catch let failure as PSNCallback.Failure {
            finish(.failure(PSNAuthorization.AuthError.callback(failure)))
        } catch {
            finish(.failure(PSNAuthorization.AuthError.invalidCallback))
        }
    }

    func closed() { finish(.failure(PSNAuthorization.AuthError.cancelled)) }

    private func finish(_ result: Result<SonyLogin, Error>) {
        guard let pending = continuation else { return }
        continuation = nil; expectedState = ""
        timeout?.cancel(); timeout = nil
        pending.resume(with: result)
    }
}

@MainActor final class AndroidApp {
    static var shared: AndroidApp?
    let model: AppModel
    let stream: StreamModel
    let device = AndroidStreamDevice()
    let page = AndroidLoginPage()
    let focus = FocusModel()
    private(set) lazy var screen: LibraryScreen = {
        let screen = LibraryScreen(model: model, focus: focus)
        screen.willChange = { [weak self] in self?.changed() }
        return screen
    }()
    private(set) var pad: PadReading?
    private var touch: PadReading?
    private var presses = LibraryPresses()
    private var polling: Task<Void, Never>?
    private var changeScheduled = false
    private var wasConnecting = false

    init(caches: URL) {
        stream = StreamModel(device: device)
        model = AppModel(store: AndroidCredentials(), website: page, player: stream, defaults: .standard, caches: caches.appendingPathComponent("Con"))
        model.willChange = { [weak self] in self?.changed() }
        stream.willChange = { [weak self] in self?.changed() }
        focus.willChange = { [weak self] in self?.changed() }
        _ = screen
        publish()
        model.reloadCatalog()
        Task { await self.model.restoreAccount() }
    }

    func take(_ reading: PadReading?) {
        let had = pad?.heldText
        pad = reading
        device.take(TouchGamepad.combine(pad, touch))
        if pad?.heldText != had, (had == nil) != (reading == nil) || model.settingsOpen && !stream.hasControls { changed() }
        guard reading != nil else { presses.reset(); polling?.cancel(); polling = nil; return }
        guard polling == nil else { return }
        polling = Task { @MainActor [weak self] in
            while !Task.isCancelled, let self, let reading = self.pad {
                for action in self.presses.take(reading.libraryActions, yielding: self.stream.hasControls, at: ProcessInfo.processInfo.systemUptime) {
                    self.screen.gamepad(action)
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    func takeTouch(_ reading: PadReading?) {
        touch = reading
        device.take(TouchGamepad.combine(pad, touch))
    }

    func changed() {
        guard !changeScheduled else { return }
        changeScheduled = true
        Task { @MainActor in
            self.changeScheduled = false
            if self.model.connectingCloud != self.wasConnecting { self.wasConnecting = self.model.connectingCloud; self.screen.connectingChanged(self.wasConnecting) }
            if self.screen.launching, self.stream.phase.isLive { self.screen.launching = false }
            self.publish()
            con_java_changed()
        }
    }

    private func publish() {
        let data = (try? JSONSerialization.data(withJSONObject: picture(), options: [.sortedKeys])) ?? Data("{}".utf8)
        Picture.set(String(decoding: data, as: UTF8.self))
    }
}

extension AndroidApp {
    static func name(_ phase: StreamPhase) -> String {
        switch phase {
        case .idle: return "idle"
        case .registering: return "registering"
        case .connecting: return "connecting"
        case .streaming: return "streaming"
        case .failed(let reason): return "failed: " + reason
        }
    }
}

enum Picture {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var text = "{}"
    static func set(_ new: String) { lock.lock(); text = new; lock.unlock() }
    static var current: String { lock.lock(); defer { lock.unlock() }; return text }
}
