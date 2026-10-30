import AppKit
import AVFoundation
import Combine
import Foundation
import GameController
import SoleCore
import SoleEngine
import SoleLogic
import SoleMedia
import SwiftUI

private final class FrameSink: StreamMedia, @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private let pipeline: VideoPipeline
    private let audio: AudioPlayback
    private var keyframeRequested: UInt64 = 0
    private let codec: VideoDecoder.Codec
    private let pacer: RefreshPacer
    var requestKeyframe: (@Sendable () -> Void)?
    init(surface: VideoSurfaceView, audio: AudioPlayback, codec: VideoDecoder.Codec) {
        self.audio = audio; self.codec = codec; pacer = surface.pacer
        pipeline = VideoPipeline(codec: codec, layer: surface.displayLayer)
        pipeline.onFailure = { [unowned self] in self.decodeFailed() }
    }
    func video(_ buffer: UnsafeBufferPointer<UInt8>, frame: Int32, display: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard active else { return true }
        return pipeline.submit(buffer, frame: frame >= 0 ? Int(frame) : nil, display: display)
    }
    private func decodeFailed() {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- keyframeRequested > 2_000_000_000 else { return }
        keyframeRequested = now
        requestKeyframe?()
    }
    func show(_ picture: StreamPicture) {
        if pipeline.frameGeneration != picture.frameGeneration { pipeline.frameGeneration = picture.frameGeneration }
        if pipeline.upscaling != picture.upscaling { pipeline.upscaling = picture.upscaling }
        if pipeline.upscaleMethod != picture.upscaleMethod { pipeline.upscaleMethod = picture.upscaleMethod }
        if pipeline.upscaleAmount != picture.upscaleAmount { pipeline.upscaleAmount = picture.upscaleAmount }
        let lead = Double(Smoothness.lead(picture.presentationLeadMs)) * 1_000_000
        if pipeline.presentationLead != lead { pipeline.presentationLead = lead }
        let byRefresh = picture.presentationLeadMs == Smoothness.byRefresh
        if (pipeline.refreshPacer != nil) != byRefresh { pipeline.refreshPacer = byRefresh ? pacer : nil }
        if pipeline.generationHeight != picture.generationHeight { pipeline.generationHeight = picture.generationHeight }
        if picture.displayHz > 0, pipeline.displayRate != Double(picture.displayHz) { pipeline.displayRate = Double(picture.displayHz) }
    }
    func counters() -> StreamMeter.Reading {
        var reading = StreamMeter.Reading()
        reading.video = pipeline.snapshot()
        let sound = audio.snapshot()
        reading.audioReceived = sound.received; reading.audioNonSilent = sound.nonSilent; reading.audioPlayed = sound.played
        reading.audioRestarts = sound.restarts; reading.audioErrors = sound.errors
        reading.askedHEVC = codec == .h265
        return reading
    }
    func audio(_ samples: UnsafeBufferPointer<Int16>, channels: Int, rate: Int) {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        audio.submit(samples, channels: channels, rate: rate)
    }
    func close() {
        lock.withLock {
            active = false
            pipeline.invalidate()
            pacer.clear()
        }
    }
}

@MainActor final class MacStreamDevice: StreamDevice {
    let surface = VideoSurfaceView()
    let keyboard = KeyboardInput()
    let dualSense = DualSenseOutput()
    private let audio = AudioPlayback()

    func openMedia(hevc: Bool) -> StreamMedia { FrameSink(surface: surface, audio: audio, codec: hevc ? .h265 : .h264) }
    func clearPicture() { surface.pacer.clear(); surface.displayLayer.flushAndRemoveImage() }
    func stopSound() { audio.stop() }
    var generationSupported: Bool { VideoPipeline.generationSupported }
    var upscalingSupported: Bool { true }
    var upscaleMethods: [Upscale.Method] { [.fsr, .anime4k, .metalFX] }
    var displayHz: Int { surface.window?.screen?.maximumFramesPerSecond ?? 0 }
    var fillsWindow = false { didSet { surface.fillsView = fillsWindow } }
    func toggleFullScreen() { surface.window?.toggleFullScreen(nil) }
    private var displayHold: NSObjectProtocol?
    func keepAwake(_ on: Bool) {
        if on, displayHold == nil {
            displayHold = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated, .latencyCritical], reason: "Game stream")
        } else if !on, let hold = displayHold {
            ProcessInfo.processInfo.endActivity(hold); displayHold = nil
        }
    }

    func beginFeedback() { dualSense.beginSession() }
    func feedback(_ report: DualSenseReport) { dualSense.send(report) }
    func haptics(_ pcm: Data) { dualSense.haptics(pcm) }
    func effectIntensity(trigger: Bool, value: UInt32) { dualSense.intensity(trigger: trigger, value: value) }
    func silenceFeedback() { dualSense.silence() }
    var playedHaptics: Int { dualSense.playedHaptics }

    func loadConsoles() -> [RegisteredConsole] { ConsoleStore.load() }
    func saveConsoles(_ consoles: [RegisteredConsole]) -> Bool { ConsoleStore.save(consoles) }

    private let pad = PadReader()
    private var inputObservers: [NSObjectProtocol] = []
    private var previousBackgroundInput: Bool?
    private var inputStarted = false

    init() {
        let pad = pad
        for name in [NSApplication.didResignActiveNotification, Notification.Name.GCControllerDidDisconnect] {
            inputObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in pad.releaseAll() })
        }
        for (name, active) in [(NSApplication.didBecomeActiveNotification, true), (NSApplication.didResignActiveNotification, false)] {
            inputObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in pad.active = active })
        }
    }

    var battery: (percent: Int, charging: Bool)? {
        guard let battery = pad.current?.battery, battery.batteryLevel > 0 else { return nil }
        return (Int((battery.batteryLevel * 100).rounded()), battery.batteryState == .charging)
    }

    func startInput(deliver: @escaping @Sendable (ControllerState?) -> Void) {
        guard !inputStarted else { return }
        inputStarted = true
        previousBackgroundInput = GCController.shouldMonitorBackgroundEvents
        GCController.shouldMonitorBackgroundEvents = true
        let keyboard = keyboard
        pad.active = NSApp.isActive
        pad.start(deliver: deliver, keyboard: { keyboard.sample(tick: $0) }, dualSense: dualSense)
        keyboard.onChange = { [pad] in pad.readSoon() }
        keyboard.start()
        surface.onPointerDown = { [weak self] in self?.keyboard.captureMouse() }
    }

    func stopInput() {
        surface.onPointerDown = nil
        keyboard.onChange = nil
        keyboard.stop()
        pad.stop()
        if let previousBackgroundInput { GCController.shouldMonitorBackgroundEvents = previousBackgroundInput }
        previousBackgroundInput = nil
        inputStarted = false
    }

    func resetMotion() { pad.resetMotion() }
    func releasePointer() { keyboard.releaseMouse() }
}

private final class PadReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.sole.gamepad", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var deliver: (@Sendable (ControllerState?) -> Void)?
    private var keyboard: (@Sendable (Bool) -> PadReading)?
    private var dualSense: DualSenseOutput?
    private weak var controller: GCController?
    private var touches = TouchSlots()
    private var motion = MotionReference()
    private var gestures: [(GCControllerButtonInput, GCControllerElement.SystemGestureState)] = []
    private let lock = NSLock()
    private var isActive = true
    private weak var currentController: GCController?

    var active: Bool {
        get { lock.withLock { isActive } }
        set { lock.withLock { isActive = newValue } }
    }
    var current: GCController? { lock.withLock { currentController } }

    func start(deliver: @escaping @Sendable (ControllerState?) -> Void, keyboard: @escaping @Sendable (Bool) -> PadReading, dualSense: DualSenseOutput) {
        queue.async { [self] in
            self.deliver = deliver; self.keyboard = keyboard; self.dualSense = dualSense
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            timer.schedule(deadline: .now(), repeating: .nanoseconds(8_000_000), leeway: .microseconds(500))
            timer.setEventHandler { [weak self] in self?.read() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel(); timer = nil
            release()
            deliver = nil; keyboard = nil
        }
    }

    func releaseAll() {
        queue.async { [self] in deliver?(nil); release() }
    }

    func readSoon() { queue.async { [self] in read(tick: false) } }

    func resetMotion() {
        queue.async { [self] in
            if let attitude = controller?.motion?.attitude { motion.reset(to: Self.rotation(attitude)) }
        }
    }

    private func release() {
        controller?.extendedGamepad?.valueChangedHandler = nil
        controller?.motion?.sensorsActive = false
        for (button, preference) in gestures { button.preferredSystemGestureState = preference }
        gestures = []
        controller = nil; touches.lift()
        lock.withLock { currentController = nil }
        dualSense?.stop()
    }

    private func read(tick: Bool = true) {
        guard let deliver, let keyboard else { return }
        guard active else { deliver(nil); return }
        let found = controller.flatMap { old in GCController.controllers().contains(where: { $0 === old }) ? old : nil }
            ?? GCController.controllers().first(where: { $0.extendedGamepad != nil })
        guard let found, let livePad = found.extendedGamepad else {
            var state = ControllerState()
            state.merge(keyboard(tick), pad: PadReading())
            deliver(state)
            return
        }
        if controller !== found {
            deliver(nil)
            release()
            controller = found
            lock.withLock { currentController = found }
            found.handlerQueue = queue
            found.motion?.sensorsActive = true
            if let attitude = found.motion?.attitude { motion.reset(to: Self.rotation(attitude)) }
            for button in [livePad.buttonOptions, livePad.buttonMenu, livePad.buttonHome].compactMap({ $0 }) {
                gestures.append((button, button.preferredSystemGestureState))
                button.preferredSystemGestureState = .disabled
            }
            if livePad is GCDualSenseGamepad { dualSense?.start() }
            livePad.valueChangedHandler = { [weak self] _, _ in self?.read(tick: false) }
        }
        var reading = livePad.capture().reading
        var state = ControllerState()
        var touchButton: GCControllerButtonInput?
        var fingers: [GCControllerDirectionPad] = []
        if let dualSensePad = livePad as? GCDualSenseGamepad {
            touchButton = dualSensePad.touchpadButton
            fingers = [dualSensePad.touchpadPrimary, dualSensePad.touchpadSecondary]
        } else if let dualShockPad = livePad as? GCDualShockGamepad {
            touchButton = dualShockPad.touchpadButton
            fingers = [dualShockPad.touchpadPrimary, dualShockPad.touchpadSecondary]
        }
        if touchButton?.isPressed == true { reading.buttons.insert(.touchpad) }
        for (slot, finger) in fingers.enumerated() {
            let x = finger.xAxis.value, y = finger.yAxis.value
            let present = (slot == 0 && touchButton?.isTouched == true) || x != 0 || y != 0
            state.setTouch(slot: slot, id: touches.id(slot: slot, present: present), x: x, y: y)
        }
        if let sensors = found.motion {
            let rate = sensors.rotationRate, gravity = sensors.gravity, acceleration = sensors.userAcceleration, orientation = sensors.attitude
            state.raw.gyroX = Float(rate.x); state.raw.gyroY = Float(rate.y); state.raw.gyroZ = Float(rate.z)
            state.raw.accelX = Float(gravity.x + acceleration.x); state.raw.accelY = Float(gravity.y + acceleration.y); state.raw.accelZ = Float(gravity.z + acceleration.z)
            let relative = motion.relative(Self.rotation(orientation))
            state.raw.orientX = Float(relative.x); state.raw.orientY = Float(relative.y); state.raw.orientZ = Float(relative.z); state.raw.orientW = Float(relative.w)
        }
        state.merge(keyboard(tick), pad: reading)
        deliver(state)
    }

    private static func rotation(_ attitude: GCQuaternion) -> MotionReference.Rotation {
        .init(x: attitude.x, y: attitude.y, z: attitude.z, w: attitude.w)
    }
}

@MainActor final class RemotePlay: StreamModel, @preconcurrency ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    private let mac: MacStreamDevice
    var surface: VideoSurfaceView { mac.surface }
    private(set) var mouseCaptured = false { willSet { objectWillChange.send() } }
    var controllerBattery: (percent: Int, charging: Bool)? { mac.battery }
    private var terminationObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        let mac = MacStreamDevice()
        self.mac = mac
        super.init(device: mac, defaults: defaults)
        willChange = { [unowned self] in self.objectWillChange.send() }
        mac.keyboard.yields = { [weak self] in self?.loginPINRequest ?? false }
        mac.keyboard.onMouseCapture = { [weak self] captured in self?.mouseCaptured = captured }
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutDown(); self?.mac.dualSense.stop(wait: true) }
        }
    }
}
