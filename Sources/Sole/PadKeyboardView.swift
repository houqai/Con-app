import SwiftUI
import SoleCore

struct PadKeyboardView: View {
    @EnvironmentObject private var focus: ControllerFocus
    let width: CGFloat
    private let gap: CGFloat = 6

    var body: some View {
        if let keyboard = focus.keyboard {
            let unit = max(26, min(50, (width - 72) / 10 - gap))
            VStack(spacing: 12) {
                VStack(spacing: gap) {
                    ForEach(Array(keyboard.rows.enumerated()), id: \.offset) { _, keys in
                        HStack(spacing: gap) {
                            ForEach(keys, id: \.self) { key in
                                let span = CGFloat(keyboard.span(key))
                                cap(key, chosen: keyboard.selected == key).frame(width: unit * span + gap * (span - 1), height: unit)
                            }
                        }
                    }
                }
                HStack(spacing: 16) {
                    hint("✕", loc("Type")); hint("□", loc("Erase")); hint("△", loc("Space")); hint("Options", loc("Done")); hint("○", loc("Close"))
                }.font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6)).lineLimit(1).fixedSize()
            }
            .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 14)
            .background(Color(red: 0.07, green: 0.08, blue: 0.13).opacity(0.94), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func cap(_ key: PadKeyboard.Key, chosen: Bool) -> some View {
        Button { focus.pressKey(key) } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(key == .done ? Color.soleAccent.opacity(chosen ? 0.55 : 0.32) : Color.white.opacity(chosen ? 0.18 : 0.07))
                face(key)
            }
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(.white.opacity(chosen ? 0.95 : 0), lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { focus.pointKey(key) } }
        .animation(.easeOut(duration: 0.1), value: chosen)
    }

    @ViewBuilder private func face(_ key: PadKeyboard.Key) -> some View {
        switch key {
        case .character(let character): Text(String(character)).font(.system(size: 18, weight: .medium))
        case .space: Image(systemName: "space").font(.system(size: 15, weight: .medium))
        case .erase: Image(systemName: "delete.left").font(.system(size: 15, weight: .medium))
        case .done: Text(loc("Done")).font(.system(size: 14, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7).padding(.horizontal, 4)
        }
    }

    private func hint(_ key: String, _ title: String) -> some View {
        HStack(spacing: 6) {
            Text(key).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 1).background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            Text(title)
        }
    }
}
