import AppKit
import SoleCore
import SoleEngine
import SoleLogic
import SwiftUI

enum MacKeys {
    static let usages: [UInt16: UInt16] = [
        0x00: 0x04, 0x01: 0x16, 0x02: 0x07, 0x03: 0x09, 0x04: 0x0B, 0x05: 0x0A, 0x06: 0x1D, 0x07: 0x1B, 0x08: 0x06, 0x09: 0x19, 0x0A: 0x64, 0x0B: 0x05,
        0x0C: 0x14, 0x0D: 0x1A, 0x0E: 0x08, 0x0F: 0x15, 0x10: 0x1C, 0x11: 0x17, 0x12: 0x1E, 0x13: 0x1F, 0x14: 0x20, 0x15: 0x21, 0x16: 0x23, 0x17: 0x22,
        0x18: 0x2E, 0x19: 0x26, 0x1A: 0x24, 0x1B: 0x2D, 0x1C: 0x25, 0x1D: 0x27, 0x1E: 0x30, 0x1F: 0x12, 0x20: 0x18, 0x21: 0x2F, 0x22: 0x0C, 0x23: 0x13,
        0x24: 0x28, 0x25: 0x0F, 0x26: 0x0D, 0x27: 0x34, 0x28: 0x0E, 0x29: 0x33, 0x2A: 0x31, 0x2B: 0x36, 0x2C: 0x38, 0x2D: 0x11, 0x2E: 0x10, 0x2F: 0x37,
        0x30: 0x2B, 0x31: 0x2C, 0x32: 0x35, 0x33: 0x2A, 0x35: 0x29, 0x36: 0xE7, 0x37: 0xE3, 0x38: 0xE1, 0x39: 0x39, 0x3A: 0xE2, 0x3B: 0xE0, 0x3C: 0xE5,
        0x3D: 0xE6, 0x3E: 0xE4, 0x40: 0x6C, 0x41: 0x63, 0x43: 0x55, 0x45: 0x57, 0x47: 0x53, 0x4B: 0x54, 0x4C: 0x58, 0x4E: 0x56, 0x4F: 0x6D, 0x50: 0x6E,
        0x51: 0x67, 0x52: 0x62, 0x53: 0x59, 0x54: 0x5A, 0x55: 0x5B, 0x56: 0x5C, 0x57: 0x5D, 0x58: 0x5E, 0x59: 0x5F, 0x5A: 0x6F, 0x5B: 0x60, 0x5C: 0x61,
        0x5D: 0x89, 0x5E: 0x87, 0x5F: 0x85, 0x60: 0x3E, 0x61: 0x3F, 0x62: 0x40, 0x63: 0x3C, 0x64: 0x41, 0x65: 0x42, 0x66: 0x91, 0x67: 0x44, 0x68: 0x90,
        0x69: 0x68, 0x6A: 0x6B, 0x6B: 0x69, 0x6D: 0x43, 0x6E: 0x65, 0x6F: 0x45, 0x71: 0x6A, 0x72: 0x49, 0x73: 0x4A, 0x74: 0x4B, 0x75: 0x4C, 0x76: 0x3D,
        0x77: 0x4D, 0x78: 0x3B, 0x79: 0x4E, 0x7A: 0x3A, 0x7B: 0x50, 0x7C: 0x4F, 0x7D: 0x51, 0x7E: 0x52,
    ]
    static let modifierBits: [UInt16: UInt] = [0x38: 0x02, 0x3C: 0x04, 0x3B: 0x01, 0x3E: 0x2000, 0x3A: 0x20, 0x3D: 0x40]

    static func translated(_ old: [String: Int]) -> [String: Int] {
        old.compactMapValues { code in (0...0xFFFF).contains(code) ? usages[UInt16(code)].map { Int($0) } : nil }
    }
}

extension KeyboardLayout {
    private static let formerStorageKey = "sole.keyboardLayout"
    static var stored: KeyboardLayout {
        get {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: storageKey) == nil, let old = defaults.dictionary(forKey: formerStorageKey) as? [String: Int] {
                KeyboardLayout(encoded: MacKeys.translated(old)).store(in: defaults)
            }
            return stored(in: defaults)
        }
        set { newValue.store(in: .standard) }
    }
}

@MainActor final class KeyboardInput {
    nonisolated(unsafe) private var play = KeyboardPlay()
    nonisolated(unsafe) private var bumpers = false
    private let playLock = NSLock()
    private func withPlay<T>(_ change: (inout KeyboardPlay) -> T) -> T { playLock.withLock { change(&play) } }
    var mouseCaptured: Bool { withPlay { $0.mouseCaptured } }
    var onMouseCapture: ((Bool) -> Void)?
    var onChange: (() -> Void)?
    private var monitor: Any?
    private var observer: NSObjectProtocol?
    var yields: () -> Bool = { false }

    private var mouse = MouseSettings(defaults: .standard)

    nonisolated func sample(tick: Bool = true) -> PadReading {
        playLock.withLock { play.sample(tick: tick, bumpers: play.mouseCaptured && bumpers) }
    }

    func start() {
        guard monitor == nil else { return }
        withPlay { $0.begin(layout: .stored) }
        let events: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged, .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                             .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
        monitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            let type = event.type
            let taken: Bool
            if type == .keyDown || type == .keyUp || type == .flagsChanged {
                let key = event.keyCode, flags = event.modifierFlags.rawValue
                taken = MainActor.assumeIsolated { self?.take(type, key: key, flags: flags) ?? false }
            } else {
                let dx = event.deltaX, dy = event.deltaY
                taken = MainActor.assumeIsolated { self?.takeMouse(type, dx: dx, dy: dy) ?? false }
            }
            return taken ? nil : event
        }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.withPlay { $0.releaseKeys() }; self?.releaseMouse() }
        }
    }
    func stop() {
        releaseMouse()
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        monitor = nil; observer = nil; withPlay { $0.releaseKeys() }
    }

    func captureMouse() {
        guard monitor != nil, !mouseCaptured, !yields() else { return }
        mouse = MouseSettings(defaults: .standard)
        guard mouse.enabled else { return }
        let settings = mouse
        withPlay { $0.captureMouse(sensitivity: settings.sensitivity) }
        playLock.withLock { bumpers = settings.bumpers }
        CGAssociateMouseAndMouseCursorPosition(0)
        NSCursor.hide()
        onMouseCapture?(true)
    }
    func releaseMouse() {
        guard withPlay({ $0.releaseMouse() }) else { return }
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
        onMouseCapture?(false)
    }

    private func takeMouse(_ type: NSEvent.EventType, dx: CGFloat, dy: CGFloat) -> Bool {
        guard mouseCaptured else { return false }
        if yields() { releaseMouse(); return false }
        let event: KeyboardPlay.MouseEvent
        switch type {
        case .leftMouseDown: event = .leftDown
        case .leftMouseUp: event = .leftUp
        case .rightMouseDown: event = .rightDown
        case .rightMouseUp: event = .rightUp
        default: event = .moved(dx: Double(dx), dy: Double(dy))
        }
        if withPlay({ $0.mouse(event) }) { onChange?() }
        return true
    }

    func take(_ type: NSEvent.EventType, key: UInt16, flags: UInt) -> Bool {
        if yields() { withPlay { $0.releaseKeys() }; return false }
        switch type {
        case .flagsChanged:
            if flags & NSEvent.ModifierFlags.command.rawValue != 0 {
                releaseMouse()
                withPlay { play in
                    play.releaseKeys()
                    for (code, bit) in MacKeys.modifierBits where flags & bit != 0 {
                        if let usage = MacKeys.usages[code] { play.modifier(usage, down: true) }
                    }
                }
                onChange?()
            }
            if let bit = MacKeys.modifierBits[key], let usage = MacKeys.usages[key] {
                withPlay { $0.modifier(usage, down: flags & bit != 0) }
                onChange?()
            }
            return false
        case .keyDown, .keyUp:
            if flags & NSEvent.ModifierFlags.command.rawValue != 0 {
                if type == .keyUp, let usage = MacKeys.usages[key], withPlay({ $0.key(usage, down: false) }) { onChange?() }
                return false
            }
            if let usage = MacKeys.usages[key], withPlay({ $0.key(usage, down: type == .keyDown) }) { onChange?() }
            return true
        default:
            return false
        }
    }
}

struct SoleKeyboardSettings: View {
    @State private var layout = KeyboardLayout.stored
    @State private var capturing: PadControl?
    @State private var monitor: Any?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Label(loc("Keyboard"), systemImage: "keyboard").font(.system(size: 16, weight: .semibold))
                    Text(loc("Works during a stream, with a controller or without one. Click a key in the list, then press the new one."))
                        .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button(loc("Reset")) { finish(); layout = .standard; KeyboardLayout.stored = layout }
                    .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Color.soleAccent).disabled(layout == .standard).opacity(layout == .standard ? 0.4 : 1)
            }
            ForEach(PadControl.groups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    TileGrid(minimum: 190, spacing: 8) {
                        ForEach(group.controls, id: \.self) { control in row(control) }
                    }
                }
            }
        }
        .padding(.vertical, 20).padding(.horizontal, 22).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.soleSurface, in: RoundedRectangle(cornerRadius: 16))
        .onDisappear { finish() }
    }
    private func row(_ control: PadControl) -> some View {
        let waiting = capturing == control
        return Button { waiting ? finish() : capture(control) } label: {
            HStack(spacing: 8) {
                Text(control.title).font(.system(size: 14)).foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 6)
                Text(waiting ? loc("press a key") : layout.keys[control].map(Key.name) ?? "—")
                    .font(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(1)
                    .padding(.horizontal, 9).frame(minWidth: 34, minHeight: 26)
                    .foregroundStyle(waiting ? Color.soleCanvas : .white)
                    .background(waiting ? Color.soleAccent : .white.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            }
            .padding(.leading, 12).padding(.trailing, 6).frame(height: 38)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).controllerTarget("key:" + control.rawValue) { waiting ? finish() : capture(control) }
    }
    private func capture(_ control: PadControl) {
        finish()
        capturing = control
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged {
                guard let bit = MacKeys.modifierBits[event.keyCode], event.modifierFlags.rawValue & bit != 0 else { return event }
            } else if event.modifierFlags.contains(.command) {
                return event
            }
            guard let usage = MacKeys.usages[event.keyCode] else { return nil }
            layout.assign(usage, to: control)
            KeyboardLayout.stored = layout
            finish()
            return nil
        }
    }
    private func finish() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; capturing = nil
    }
}

struct SoleMouseSettings: View {
    @AppStorage(MouseSettings.enabledKey) private var enabled = true
    @AppStorage(MouseSettings.sensitivityKey) private var sensitivity = MouseSettings.standardSensitivity
    @AppStorage(MouseSettings.buttonsKey) private var buttons = "triggers"
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Label(loc("Mouse"), systemImage: "computermouse").font(.system(size: 16, weight: .semibold))
                    Text(loc("Click the picture during a stream: the pointer disappears and the mouse turns the camera. The ⌘ key brings the pointer back."))
                        .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                DesignToggle(isOn: $enabled, label: loc("Mouse camera"))
            }
            if enabled {
                HStack(spacing: 14) {
                    Text(loc("Sensitivity")).font(.system(size: 14)).foregroundStyle(.white.opacity(0.85))
                    Spacer(minLength: 6)
                    Slider(value: $sensitivity, in: MouseSettings.sensitivities, step: 1).frame(maxWidth: 220)
                        .controllerTarget("mouse-sensitivity", adjust: { sensitivity = min(MouseSettings.sensitivities.upperBound, max(MouseSettings.sensitivities.lowerBound, sensitivity + Double($0))) }) {}
                    Text("\(Int(sensitivity))").font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit().frame(width: 22, alignment: .trailing)
                }
                HStack(spacing: 14) {
                    Text(loc("Mouse buttons")).font(.system(size: 14)).foregroundStyle(.white.opacity(0.85))
                    Spacer(minLength: 6)
                    DesignSelect(selection: $buttons, values: MouseSettings.buttonChoices.map { ($0.value, $0.title) }, label: loc("Mouse buttons"), width: 250)
                }
            }
        }
        .padding(.vertical, 20).padding(.horizontal, 22).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.soleSurface, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct TileGrid: Layout {
    var minimum: CGFloat
    var spacing: CGFloat
    private func columns(_ width: CGFloat) -> Int { max(1, Int((width + spacing) / (minimum + spacing))) }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minimum
        let across = columns(width), tile = (width - CGFloat(across - 1) * spacing) / CGFloat(across)
        var height: CGFloat = 0
        for start in stride(from: 0, to: subviews.count, by: across) {
            let row = subviews[start..<min(start + across, subviews.count)].map { $0.sizeThatFits(ProposedViewSize(width: tile, height: nil)).height }.max() ?? 0
            height += row + (start > 0 ? spacing : 0)
        }
        return CGSize(width: width, height: height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let across = columns(bounds.width), tile = (bounds.width - CGFloat(across - 1) * spacing) / CGFloat(across)
        var y = bounds.minY
        for start in stride(from: 0, to: subviews.count, by: across) {
            let row = subviews[start..<min(start + across, subviews.count)]
            let height = row.map { $0.sizeThatFits(ProposedViewSize(width: tile, height: nil)).height }.max() ?? 0
            for (index, view) in row.enumerated() {
                view.place(at: CGPoint(x: bounds.minX + CGFloat(index) * (tile + spacing), y: y), proposal: ProposedViewSize(width: tile, height: height))
            }
            y += height + spacing
        }
    }
}
