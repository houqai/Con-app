import XCTest
import SoleCore
import SoleEngine
@testable import SoleLogic

final class StreamModelTests: XCTestCase {
    private final class Media: StreamMedia, @unchecked Sendable {
        var requestKeyframe: (@Sendable () -> Void)?
        var shown: [StreamPicture] = []
        var closed = 0
        var reading = StreamMeter.Reading()
        func video(_ buffer: UnsafeBufferPointer<UInt8>, frame: Int32, display: Bool) -> Bool { true }
        func audio(_ samples: UnsafeBufferPointer<Int16>, channels: Int, rate: Int) {}
        func counters() -> StreamMeter.Reading { reading }
        func show(_ picture: StreamPicture) { shown.append(picture) }
        func close() { closed += 1 }
    }
    @MainActor private final class Device: StreamDevice {
        var calls: [String] = []
        var media: [Media] = []
        var deliver: ((ControllerState?) -> Void)?
        var stored: [RegisteredConsole] = []
        var generationSupported = true
        var displayHz = 60
        var fillsWindow = false
        var playedHaptics = 0
        func openMedia(hevc: Bool) -> StreamMedia { calls.append(hevc ? "media hevc" : "media avc"); let one = Media(); media.append(one); return one }
        func clearPicture() { calls.append("clear") }
        func stopSound() { calls.append("silence") }
        func toggleFullScreen() { calls.append("full screen") }
        var awake = false
        func keepAwake(_ on: Bool) { if on != awake { awake = on; calls.append("awake \(on)") } }
        func startInput(deliver: @escaping (ControllerState?) -> Void) { calls.append("input"); self.deliver = deliver }
        func stopInput() { calls.append("no input"); deliver = nil }
        func resetMotion() { calls.append("motion") }
        func releasePointer() { calls.append("pointer") }
        func beginFeedback() { calls.append("feedback") }
        func feedback(_ report: DualSenseReport) { calls.append("report \(report.effects[0]) \(report.effects[1])") }
        func haptics(_ pcm: Data) { calls.append("haptics \(pcm.count)") }
        func effectIntensity(trigger: Bool, value: UInt32) { calls.append("intensity \(trigger) \(value)") }
        func silenceFeedback() { calls.append("silence") }
        func loadConsoles() -> [RegisteredConsole] { stored }
        var saves = true
        func saveConsoles(_ consoles: [RegisteredConsole]) -> Bool {
            guard saves else { return false }
            stored = consoles; calls.append("save \(consoles.map(\.hostID))")
            return true
        }
        func takeCalls() -> [String] { defer { calls = [] }; return calls }
    }
    private func credentials() -> RemotePlayCredentials {
        RemotePlayCredentials(registKey: Array(0..<16), morning: Array(16..<32), targetValue: 1_000_100, serverMAC: [1, 2, 3, 4, 5, 6], consolePIN: 0)
    }
    private func stream(ps5: Bool = true) -> CloudStream {
        let slot = CloudStreamSlot(host: "127.0.0.1", port: 9, packetPrefix: 9, launchSpecification: "spec", sessionID: "session-1",
                                   handshakeKey: Data(repeating: 7, count: 16), mtuIn: 1454, mtuOut: 1254, rttMs: 30, isPS5: ps5)
        return CloudStream(slot: slot, title: "Astro Bot · PS5", resolution: 1080, server: "Frankfurt", measuredPingMs: 40, reportedPingMs: 40,
                           game: StreamGame(title: "Astro Bot", platform: "PS5"), status: "")
    }
    private static func press(_ buttons: ControllerState.Button) -> ControllerState { var state = ControllerState(); state.setButtons(buttons); return state }

    @MainActor func testRegisteredConsolesAreReadKeptAndForgotten() async {
        let device = Device()
        device.stored = [RegisteredConsole(hostID: "a", name: "PS5", isPS5: true, credentials: credentials())]
        let model = StreamModel(device: device, defaults: testSettings())
        XCTAssertTrue(model.isRegistered("a")); XCTAssertFalse(model.isRegistered("b"))
        model.remember(RegisteredConsole(hostID: "b", name: "PS4", isPS5: false, credentials: credentials()))
        model.remember(RegisteredConsole(hostID: "a", name: "PS5 again", isPS5: true, credentials: credentials()))
        XCTAssertEqual(model.registered.map(\.name), ["PS4", "PS5 again"], "Re-registering a console replaces its earlier entry")
        XCTAssertEqual(device.stored.map(\.hostID), ["b", "a"])
        XCTAssertEqual(model.offlineRegistered.map(\.hostID), ["b", "a"], "Consoles not found on the network are listed as offline")
        model.removeRegistration(hostID: "b")
        XCTAssertEqual(device.stored.map(\.hostID), ["a"])
        device.saves = false
        XCTAssertFalse(model.remember(RegisteredConsole(hostID: "c", name: "PS5 new", isPS5: true, credentials: credentials())))
        model.removeRegistration(hostID: "a")
        XCTAssertEqual(model.phase, .failed(loc("Could not remove the registration: the console will appear again after Con restarts.")), "A registration that cannot be removed from the keychain reappears at the next start, and the user is told")
    }

    func testAPhaseSaysWhetherAStreamHasTheControlsAndWhetherSomethingIsUnderWay() {
        let phases: [(StreamPhase, live: Bool, busy: Bool)] = [
            (.idle, false, false), (.failed("x"), false, false), (.registering(hostID: "a"), false, true),
            (.connecting(hostID: "a"), true, true), (.streaming(hostID: StreamPhase.cloudHostID), true, true),
        ]
        for (phase, live, busy) in phases {
            XCTAssertEqual(phase.isLive, live, "\(phase)"); XCTAssertEqual(phase.isBusy, busy, "\(phase)")
        }
    }

    @MainActor func testAConsoleIsNotRegisteredOrJoinedWithoutWhatItNeeds() async {
        let device = Device()
        let model = StreamModel(device: device, defaults: testSettings())
        let console = DiscoveredConsole(hostID: "a", name: "PS5", address: "127.0.0.1", isPS5: true, state: .ready, systemVersion: nil, targetValue: 1_000_100)
        await model.register(console: console, pin: "12345678")
        guard case .failed = model.phase else { return XCTFail("Nobody is signed in") }
        model.clearFailure()
        XCTAssertEqual(model.phase, .idle)
        model.accountProvider = { [0, 0, 0, 0, 0, 0, 0, 1] }
        await model.register(console: console, pin: "1234")
        XCTAssertEqual(model.phase, .failed(Localization.text("Enter the 8-digit registration code from the console.", in: .english)))
        await model.connect(console: console)
        XCTAssertEqual(model.phase, .failed(Localization.text("The console is not registered.", in: .english)))
        XCTAssertFalse(device.calls.contains("media avc"), "Nothing was started")
    }

    @MainActor func testACloudStreamIsStartedShownAndLeftFromItsMenu() async {
        let device = Device()
        let defaults = testSettings()
        let model = StreamModel(device: device, defaults: defaults)
        var ended: [String?] = []
        var notifications = 0
        model.cloudEnded = { ended.append($0) }
        model.willChange = { notifications += 1 }
        model.connectCloud(stream())
        XCTAssertEqual(model.phase, .connecting(hostID: StreamPhase.cloudHostID))
        XCTAssertEqual(model.streamGame?.title, "Astro Bot")
        XCTAssertEqual(device.takeCalls(), ["no input", "silence", "clear", "feedback", "awake true", "clear", "media hevc"], "The previous stream is ended before the new one is set up")
        XCTAssertNotNil(device.media[0].requestKeyframe)
        XCTAssertGreaterThan(notifications, 2)

        model.handle(.connected, hostID: StreamPhase.cloudHostID, name: "Astro Bot · PS5")
        XCTAssertEqual(model.phase, .streaming(hostID: StreamPhase.cloudHostID))
        XCTAssertEqual(device.takeCalls(), ["input"])
        XCTAssertEqual(model.stats?.server, "Frankfurt"); XCTAssertEqual(model.stats?.measuredPingMs, 40); XCTAssertEqual(model.stats?.displayHz, 60)
        XCTAssertEqual(device.media[0].shown, [StreamPicture(frameGeneration: false, presentationLeadMs: 21, generationHeight: 720, displayHz: 60)], "Fresh-install defaults")

        device.deliver?(Self.press(.ps))
        XCTAssertTrue(model.menu.isOpen)
        XCTAssertEqual(device.takeCalls(), ["pointer"])
        device.deliver?(Self.press([]))
        model.pointMenu(at: .leave)
        device.deliver?(Self.press(.cross))
        XCTAssertFalse(model.menu.isOpen)
        XCTAssertEqual(model.phase, .idle); XCTAssertNil(model.stats); XCTAssertNil(model.streamGame); XCTAssertNil(model.statusText)
        XCTAssertEqual(ended, [nil], "Reported once, as a normal end")
        XCTAssertEqual(device.takeCalls(), ["no input", "silence", "clear", "awake false"])
        XCTAssertEqual(device.media[0].closed, 1)
        model.disconnect()
        XCTAssertEqual(ended, [nil], "Nothing is running, so nothing is reported")
    }

    @MainActor func testTheMenuActsOnTheStreamAndOnItsSettings() async {
        let device = Device()
        let defaults = testSettings()
        let model = StreamModel(device: device, defaults: defaults)
        model.connectCloud(stream(ps5: false))
        XCTAssertTrue(device.calls.contains("media avc"), "A PS4 or PS3 game is streamed as H.264")
        model.handle(.connected, hostID: StreamPhase.cloudHostID, name: "x")
        model.choose(.stats)
        XCTAssertTrue(model.statsVisible); XCTAssertTrue(defaults.bool(forKey: StreamModel.statsKey))
        model.choose(.generation)
        XCTAssertTrue(model.frameGeneration)
        device.generationSupported = false
        model.choose(.generation)
        XCTAssertTrue(model.frameGeneration, "The row does nothing where frame generation is unsupported")
        _ = device.takeCalls()
        model.choose(.fullScreen)
        XCTAssertEqual(device.takeCalls(), ["full screen"])
        defaults.set(1080, forKey: StreamModel.generationHeightKey); defaults.set(8, forKey: Smoothness.key)
        device.displayHz = 120
        model.sampleStats()
        XCTAssertEqual(device.media[0].shown.last, StreamPicture(frameGeneration: true, presentationLeadMs: 8, generationHeight: 1080, displayHz: 120))
        model.fillsWindow = true
        XCTAssertTrue(device.fillsWindow)
        model.disconnect()
    }

    @MainActor func testWhatTheGameSendsReachesTheGamepadUnlessVibrationIsOff() async {
        let device = Device()
        let model = StreamModel(device: device, defaults: testSettings())
        model.connectCloud(stream())
        model.handle(.connected, hostID: StreamPhase.cloudHostID, name: "x")
        _ = device.takeCalls()
        let effect = [UInt8](repeating: 1, count: 11)
        model.handle(.rumble(left: 9, right: 9), hostID: "x", name: "x")
        model.handle(.haptics(Data([1, 2, 3, 4])), hostID: "x", name: "x")
        model.handle(.triggerEffects(left: effect, right: effect), hostID: "x", name: "x")
        model.handle(.effectIntensity(trigger: true, value: 2), hostID: "x", name: "x")
        model.handle(.motionReset, hostID: "x", name: "x")
        XCTAssertEqual(device.takeCalls(), ["report 3 0", "haptics 4", "report 12 0", "intensity true 2", "motion"])
        model.vibration = false
        XCTAssertEqual(device.takeCalls(), ["silence"], "Ongoing vibration is stopped")
        model.vibration = false
        model.handle(.rumble(left: 9, right: 9), hostID: "x", name: "x")
        model.handle(.haptics(Data([1, 2, 3, 4])), hostID: "x", name: "x")
        model.handle(.led(red: 1, green: 2, blue: 3), hostID: "x", name: "x")
        model.handle(.triggerEffects(left: effect, right: effect), hostID: "x", name: "x")
        XCTAssertEqual(device.takeCalls(), ["report 0 4", "report 12 0"], "The light bar and triggers keep working")
        model.sampleStats()
        XCTAssertEqual(model.stats?.hapticPackets, 2, "Packets are counted whether played or not")
        XCTAssertEqual(model.stats?.triggerPackets, 2)
        model.disconnect()
    }

    @MainActor func testAReadingFromAnotherThreadReachesTheMenu() async {
        let device = Device()
        let model = StreamModel(device: device, defaults: testSettings())
        model.connectCloud(stream())
        model.handle(.connected, hostID: StreamPhase.cloudHostID, name: "x")
        _ = device.takeCalls()
        let deliver = device.deliver
        await Task.detached { XCTAssertFalse(Thread.isMainThread); deliver?(Self.press(.ps)) }.value
        for _ in 0..<50 where !model.menu.isOpen { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(model.menu.isOpen)
        XCTAssertEqual(device.takeCalls(), ["pointer"])
        model.disconnect()
    }

    @MainActor func testTheEndOfAStreamIsSaidWhereItBelongs() async {
        let device = Device()
        let model = StreamModel(device: device, defaults: testSettings())
        var ended: [String?] = []
        model.cloudEnded = { ended.append($0) }
        model.handle(.connected, hostID: StreamPhase.cloudHostID, name: "x")
        XCTAssertEqual(device.takeCalls(), ["awake true", "input"])
        model.handle(.quit(reason: "the line dropped", isError: true), hostID: StreamPhase.cloudHostID, name: "x")
        XCTAssertEqual(ended, ["the line dropped"]); XCTAssertEqual(model.phase, .idle); XCTAssertNil(model.stats)
        XCTAssertEqual(device.takeCalls(), ["silence", "no input", "awake false"])
        model.handle(.connected, hostID: StreamPhase.cloudHostID, name: "x")
        model.handle(.quit(reason: "bye", isError: false), hostID: StreamPhase.cloudHostID, name: "x")
        XCTAssertEqual(ended, ["the line dropped", nil], "A normal end")
        model.handle(.loginPINRequired(incorrect: false), hostID: "console", name: "PS5")
        XCTAssertTrue(model.loginPINRequest); XCTAssertNotNil(model.statusText)
        model.submitLoginPIN("12 34")
        XCTAssertFalse(model.loginPINRequest)
        model.handle(.quit(reason: "Stopped", isError: false), hostID: "console", name: "PS5")
        XCTAssertEqual(model.phase, .idle); XCTAssertNotNil(model.statusText)
        model.handle(.quit(reason: "boom", isError: true), hostID: "console", name: "PS5")
        XCTAssertEqual(model.phase, .failed("boom")); XCTAssertNil(model.statusText)
        XCTAssertEqual(ended, ["the line dropped", nil], "Only cloud streams report to the game page")
    }

    func testTheEndOfAStreamNamesTheStepItEndedInWhenTheEngineSaysIt() {
        XCTAssertEqual(StreamModel.quitLine(reason: "Stream: remote disconnected", isError: true, stage: "key exchange"),
                       "quit error=true reason=Stream: remote disconnected stage=key exchange")
        XCTAssertEqual(StreamModel.quitLine(reason: "Stopped", isError: false, stage: nil), "quit error=false reason=Stopped", "Without a stage the line is unchanged")
    }

    func testTheDiagnosticsNameTheEnginesVersion() {
        XCTAssertEqual(StreamModel.engineLine, "engine=rust \(SoleEngine.version)")
    }

    @MainActor func testTheVideoIsCapturedOnlyWhenAskedFor() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment[VideoCaptureChoice.environmentKey] != nil, "CON_VIDEO_CAPTURE overrides the setting")
        let off = StreamModel(device: Device(), defaults: testSettings())
        let on = StreamModel(device: Device(), defaults: testSettings([VideoCaptureChoice.settingKey: true]))
        XCTAssertFalse(off.capturesVideo, "Off by default")
        XCTAssertTrue(on.capturesVideo)
    }

    func testEachCaptureStartsWithAFreshFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("con-capture-\(UUID().uuidString)/diagnostics")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let path = try XCTUnwrap(StreamModel.freshVideoCapture(in: folder), "The folder is created")
        XCTAssertEqual(path, folder.appendingPathComponent("video-capture.bin").path)
        try Data("CONVCAP1 of the last stream".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(StreamModel.freshVideoCapture(in: folder), path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "The engine appends to a capture, so the previous one is deleted first")
        XCTAssertNil(StreamModel.freshVideoCapture(in: nil))
    }

    @MainActor func testWithAConsoleThePSButtonIsTheConsoles() async {
        let device = Device()
        let model = StreamModel(device: device, defaults: testSettings())
        model.connectCloud(stream())
        model.handle(.connected, hostID: "console", name: "PS5")
        XCTAssertEqual(model.phase, .streaming(hostID: "console"))
        device.deliver?(Self.press(.ps))
        XCTAssertFalse(model.menu.isOpen, "The PS button goes to the console's own menu")
        device.deliver?(nil)
        XCTAssertFalse(model.menu.isOpen)
        model.disconnect()
    }

    func testTheSmoothnessIsKeptInStepsAndReadFromTheSwitchOfBefore() {
        let defaults = testSettings()
        XCTAssertEqual(Smoothness.read(defaults), 21, "Fresh install defaults to the maximum")
        defaults.set(false, forKey: StreamModel.evenPresentationKey)
        XCTAssertEqual(Smoothness.read(defaults), 0, "Legacy switch off maps to 0")
        defaults.set(true, forKey: StreamModel.evenPresentationKey)
        XCTAssertEqual(Smoothness.read(defaults), 21, "Legacy switch on maps to the maximum")
        defaults.set(12, forKey: Smoothness.key)
        XCTAssertEqual(Smoothness.read(defaults), 12, "The level setting overrides the legacy switch")
        defaults.set(10, forKey: Smoothness.key)
        XCTAssertTrue([8, 12].contains(Smoothness.read(defaults)), "Values between levels snap to a level")
        XCTAssertEqual(Smoothness.levels.first, 0); XCTAssertEqual(Smoothness.levels.last, Int(PresentationClock.lead / 1_000_000))
        defaults.set(Smoothness.byRefresh, forKey: Smoothness.key)
        XCTAssertEqual(Smoothness.read(defaults), Smoothness.byRefresh)
        XCTAssertEqual(Smoothness.lead(Smoothness.byRefresh), 0)
        XCTAssertEqual(Smoothness.choices(byRefresh: true).map(\.0), [0, Smoothness.byRefresh, 4, 8, 12, 16, 21])
        XCTAssertEqual(Smoothness.choices(byRefresh: false).map(\.0), [0, 4, 8, 12, 16, 21])
    }
}
