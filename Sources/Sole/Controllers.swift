import SwiftUI
import SoleCore
import SoleEngine
import SoleLogic
import GameController

extension GCExtendedGamepad {
    var reading: PadReading {
        var reading = PadReading()
        if buttonA.isPressed { reading.buttons.insert(.cross) }
        if buttonB.isPressed { reading.buttons.insert(.circle) }
        if buttonX.isPressed { reading.buttons.insert(.square) }
        if buttonY.isPressed { reading.buttons.insert(.triangle) }
        if dpad.up.isPressed { reading.buttons.insert(.dpadUp) }
        if dpad.down.isPressed { reading.buttons.insert(.dpadDown) }
        if dpad.left.isPressed { reading.buttons.insert(.dpadLeft) }
        if dpad.right.isPressed { reading.buttons.insert(.dpadRight) }
        if leftShoulder.isPressed { reading.buttons.insert(.l1) }
        if rightShoulder.isPressed { reading.buttons.insert(.r1) }
        if leftThumbstickButton?.isPressed == true { reading.buttons.insert(.l3) }
        if rightThumbstickButton?.isPressed == true { reading.buttons.insert(.r3) }
        if buttonMenu.isPressed { reading.buttons.insert(.options) }
        if buttonOptions?.isPressed == true { reading.buttons.insert(.share) }
        if buttonHome?.isPressed == true { reading.buttons.insert(.ps) }
        reading.l2 = leftTrigger.value; reading.r2 = rightTrigger.value
        reading.leftX = leftThumbstick.xAxis.value; reading.leftY = leftThumbstick.yAxis.value
        reading.rightX = rightThumbstick.xAxis.value; reading.rightY = rightThumbstick.yAxis.value
        return reading
    }
}

@MainActor final class ControllerMonitor: ObservableObject {
    struct Device: Identifiable {
        let id: ObjectIdentifier
        let name: String
        let battery: Int?
        let charging: Bool
        let supportsHaptics: Bool
        let pressed: String
    }
    @Published private(set) var devices: [Device] = []
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var active = false

    func start() {
        guard !active else { return }
        active = true
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }
    func stop() {
        timer?.invalidate()
        timer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        active = false
    }
    private func refresh() {
        devices = GCController.controllers().map { controller in
            let level = controller.battery?.batteryLevel
            return Device(id: ObjectIdentifier(controller), name: controller.vendorName ?? loc("Controller"),
                          battery: level.flatMap { $0 >= 0 ? Int(($0 * 100).rounded()) : nil },
                          charging: controller.battery?.batteryState == .charging,
                          supportsHaptics: controller.haptics != nil,
                          pressed: (controller.extendedGamepad?.reading ?? PadReading()).heldText)
        }
    }
}

struct SoleControllers: View {
    @StateObject private var monitor = ControllerMonitor()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if monitor.devices.isEmpty {
                Label(loc("No controller connected"), systemImage: "gamecontroller").font(.system(size: 15, weight: .medium))
                Text(loc("Connect a DualSense, DualShock or another compatible controller to your Mac over USB or Bluetooth. Con will find it automatically. Without a controller you can play with the keyboard."))
                    .font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(monitor.devices) { device in
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "gamecontroller.fill").foregroundStyle(Color.soleAccent)
                        Text(device.name).font(.system(size: 16, weight: .semibold))
                        Spacer()
                        if let battery = device.battery {
                            Label("\(battery)%", systemImage: device.charging ? "battery.100percent.bolt" : "battery.100percent")
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                    Text(device.pressed).font(.system(size: 14, design: .monospaced)).foregroundStyle(Color.soleAccent)
                    Text(device.supportsHaptics ? loc("The controller supports haptic feedback") : loc("Haptic feedback is not available"))
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }.padding(.vertical, 20).padding(.horizontal, 22).frame(maxWidth: .infinity, alignment: .leading).background(Color.soleSurface, in: RoundedRectangle(cornerRadius: 16))
            }
            Text(loc("The input check works locally. During a stream the game is controlled by the first connected controller and the keyboard, together or separately."))
                .font(.system(size: 13)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }.onAppear { monitor.start() }.onDisappear { monitor.stop() }
    }
}

struct DesignControllerInput: NSViewRepresentable {
    var yields: () -> Bool = { false }
    let action: (LibraryControllerAction) -> Void
    final class Coordinator {
        var action: (LibraryControllerAction) -> Void
        var yields: () -> Bool
        var timer: Timer?
        var presses = LibraryPresses()
        init(yields: @escaping () -> Bool, action: @escaping (LibraryControllerAction) -> Void) {
            self.yields = yields
            self.action = action
        }
        deinit { timer?.invalidate() }
        @MainActor func poll() {
            guard NSApp.isActive,
                  let pad = GCController.controllers().first?.extendedGamepad else {
                presses.reset(); return
            }
            for button in presses.take(pad.reading.libraryActions, yielding: yields(), at: Date.timeIntervalSinceReferenceDate) { action(button) }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(yields: yields, action: action) }
    func makeNSView(context: Context) -> NSView {
        context.coordinator.timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak coordinator = context.coordinator] _ in
            Task { @MainActor in coordinator?.poll() }
        }
        return NSView()
    }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.action = action
        context.coordinator.yields = yields
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.timer?.invalidate(); coordinator.timer = nil }
}
