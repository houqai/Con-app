import Combine
import SwiftUI
import SoleCore
import SoleLogic

struct ControllerTarget: Equatable {
    let id: String
    let rect: CGRect
    let activate: () -> Void
    var adjust: ((Int) -> Void)? = nil
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.rect == rhs.rect }
}

struct ControllerTargets: PreferenceKey {
    static var defaultValue: [ControllerTarget] = []
    static func reduce(value: inout [ControllerTarget], nextValue: () -> [ControllerTarget]) { value += nextValue() }
}

@MainActor final class ControllerFocus: FocusModel, @preconcurrency ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    override init() {
        super.init()
        willChange = { [unowned self] in self.objectWillChange.send() }
    }
    private(set) var targets: [ControllerTarget] = []
    func update(_ values: [ControllerTarget]) {
        targets = values.filter { $0.rect.width > 0 && $0.rect.height > 0 }
        update(targets.map { FocusTarget(id: $0.id, at: (Double($0.rect.midX), Double($0.rect.midY)), activate: $0.activate, adjust: $0.adjust) })
    }
}

struct ControllerFocusModifier: ViewModifier {
    @EnvironmentObject var focus: ControllerFocus
    @Environment(\.isEnabled) var enabled
    let id: String
    let action: () -> Void
    var adjust: ((Int) -> Void)?
    func body(content: Content) -> some View {
        content.overlay {
            if enabled, focus.isFocused(id), !id.hasPrefix("game:") {
                GeometryReader { geometry in
                    RoundedRectangle(cornerRadius: corner(geometry.size) + Self.gap, style: .continuous)
                        .stroke(.white, lineWidth: 3)
                        .padding(-Self.gap)
                        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                }.allowsHitTesting(false)
            }
        }.background {
            GeometryReader { geometry in
                Color.clear.preference(key: ControllerTargets.self, value: enabled ? [ControllerTarget(id: id, rect: geometry.frame(in: .global), activate: action, adjust: adjust)] : [])
            }
        }
    }
    private static let gap: CGFloat = 6
    private func corner(_ size: CGSize) -> CGFloat {
        let round = min(size.width, size.height) / 2
        let capsule = id.hasPrefix("filter:") || id.hasPrefix("page-") || id.hasPrefix("account-") || id.hasPrefix("console-")
            || id == LibraryScreen.Target.launchCancel || id == LibraryScreen.Target.search || id == LibraryScreen.Target.more || id.hasPrefix("toggle:")
            || id.hasPrefix("icon:") || id == "header-menu" || (id == "account" && size.width < 50)
        if capsule { return round }
        if id.hasPrefix("quality:") { return 14 }
        if id.hasPrefix(LibraryScreen.Target.recentPrefix) { return 12 }
        if id.hasPrefix(LibraryScreen.Target.settingsTabPrefix) { return size.height < 42 ? round : 12 }
        if id == "bitrate" || id.hasPrefix("nav:") || id == "account" { return 8 }
        return 10
    }
}

extension View {
    func controllerTarget(_ id: String, adjust: ((Int) -> Void)? = nil, action: @escaping () -> Void) -> some View {
        modifier(ControllerFocusModifier(id: id, action: action, adjust: adjust)).id(id)
    }
}

struct ControllerChoices: View {
    @EnvironmentObject var focus: ControllerFocus
    var body: some View {
        if !focus.choices.isEmpty {
            ZStack {
                Color.black.opacity(0.55).onTapGesture { focus.choices = [] }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(focus.choices.indices, id: \.self) { index in
                                Button { let choice = focus.choices[index]; focus.choices = []; choice.action() } label: {
                                    Text(focus.choices[index].title).font(.system(size: 16)).frame(maxWidth: .infinity, alignment: .leading).padding(14)
                                        .background(index == focus.choiceIndex ? Color.soleAccent.opacity(0.3) : .clear, in: RoundedRectangle(cornerRadius: 10))
                                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white, lineWidth: index == focus.choiceIndex ? 2 : 0))
                                }.buttonStyle(.plain).id(index)
                            }
                        }.padding(16)
                    }
                    .scrollIndicators(.hidden)
                    .frame(height: min(360, CGFloat(focus.choices.count) * 60 + 32))
                    .onAppear { proxy.scrollTo(focus.choiceIndex, anchor: .center) }
                    .onChange(of: focus.choiceIndex) { _, index in proxy.scrollTo(index) }
                }.frame(width: 360).background(Color(red: 18/255, green: 21/255, blue: 34/255), in: RoundedRectangle(cornerRadius: 18))
            }
        }
    }
}
