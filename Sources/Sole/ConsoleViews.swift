import SwiftUI
import SoleLogic
import SoleCore
import SoleEngine
import SoleMedia

struct SoleConsoles: View {
    @EnvironmentObject private var model: SoleModel
    @ObservedObject private var remotePlay: RemotePlay
    @State private var registering: DiscoveredConsole?
    @State private var pin = ""

    init(remotePlay: RemotePlay) { self.remotePlay = remotePlay }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if model.account == nil {
                    banner(loc("Sign in to PlayStation to register consoles and start Remote Play."), action: loc("Connect PlayStation")) { model.loginOpen = true }
                }
                if let status = remotePlay.statusText { banner(status) }
                if case .failed(let message) = remotePlay.phase { banner(message, tint: .orange) { remotePlay.clearFailure() } }

                HStack(spacing: 8) {
                    Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(Color.soleAccent)
                    Text(loc("On the local network")).font(.system(size: 16, weight: .semibold))
                    ProgressView().controlSize(.small).opacity(remotePlay.consoles.isEmpty ? 1 : 0)
                }.padding(.top, 4)

                if remotePlay.consoles.isEmpty {
                    Text(loc("Looking for PlayStation consoles on the network. Make sure your PS5 or PS4 is on, is on the same network, and has Remote Play enabled in its settings."))
                        .font(.system(size: 15)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(remotePlay.consoles) { console in
                    consoleRow(console)
                }
                if !remotePlay.offlineRegistered.isEmpty {
                    Text(loc("Saved")).font(.system(size: 16, weight: .semibold)).padding(.top, 10)
                    ForEach(remotePlay.offlineRegistered) { entry in offlineRow(entry) }
                }
                Text(loc("Remote Play connects directly to your console on the local network. It is separate from cloud streaming."))
                    .font(.system(size: 13)).foregroundStyle(.tertiary).padding(.top, 10).fixedSize(horizontal: false, vertical: true)
            }.padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
        .sheet(item: $registering) { console in
            registrationSheet(console)
        }
    }

    private func consoleRow(_ console: DiscoveredConsole) -> some View {
        let registered = remotePlay.isRegistered(console.id)
        return HStack(spacing: 14) {
            Image(systemName: console.isPS5 ? "visionpro" : "gamecontroller")
                .font(.system(size: 20)).foregroundStyle(Color.soleAccent).frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(console.name.isEmpty ? console.address : console.name).font(.system(size: 14, weight: .medium))
                HStack(spacing: 6) {
                    Text(console.isPS5 ? "PS5" : "PS4").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    stateBadge(console.state)
                }
            }
            Spacer()
            if registered {
                Button(loc("Play")) { play(console) }
                    .buttonStyle(QuietButton(prominent: true)).disabled(busy || model.account == nil).controllerTarget("console-play:" + console.id) { play(console) }
                Menu {
                    Button(loc("Remove registration"), role: .destructive) { remotePlay.removeRegistration(hostID: console.id) }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 22)
            } else {
                Button(loc("Connect")) { startRegistering(console) }
                    .buttonStyle(QuietButton()).disabled(busy || model.account == nil).controllerTarget("console-register:" + console.id) { startRegistering(console) }
            }
        }.padding(15).background(Color.soleSurface, in: RoundedRectangle(cornerRadius: 10))
    }

    private func play(_ console: DiscoveredConsole) {
        Task { await remotePlay.connect(console: console) }
    }

    private func startRegistering(_ console: DiscoveredConsole) {
        pin = ""
        registering = console
    }

    private func remove(_ entry: RegisteredConsole) {
        remotePlay.removeRegistration(hostID: entry.hostID)
    }

    private func offlineRow(_ entry: RegisteredConsole) -> some View {
        HStack(spacing: 14) {
            Image(systemName: entry.isPS5 ? "visionpro" : "gamecontroller").font(.system(size: 20)).foregroundStyle(.tertiary).frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name).font(.system(size: 14, weight: .medium))
                Text(loc("Offline")).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer()
            Button(loc("Remove"), role: .destructive) { remove(entry) }.buttonStyle(QuietButton()).controllerTarget("console-remove:" + entry.hostID) { remove(entry) }
        }.padding(15).background(Color.soleSurface, in: RoundedRectangle(cornerRadius: 10)).opacity(0.7)
    }

    private func stateBadge(_ state: DiscoveredConsole.State) -> some View {
        let (text, colour): (String, Color) = switch state {
        case .ready: (loc("Ready"), .green)
        case .standby: (loc("Rest mode"), .yellow)
        case .unknown: (loc("Unknown"), .gray)
        }
        return Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(colour)
            .padding(.horizontal, 7).padding(.vertical, 2).background(colour.opacity(0.14), in: Capsule())
    }

    private var busy: Bool { remotePlay.phase.isBusy }

    private func registrationSheet(_ console: DiscoveredConsole) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(loc("Register %@", console.name.isEmpty ? console.address : console.name)).font(.system(size: 15, weight: .semibold))
            Text(loc("On the console, open Settings → System → Remote Play → Link Device and enter the 8-digit code shown."))
                .font(.system(size: 15)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField(loc("8-digit code"), text: $pin).textFieldStyle(.roundedBorder).font(.system(size: 18, design: .monospaced))
                .onChange(of: pin) { _, value in pin = String(value.filter(\.isNumber).prefix(8)) }
            HStack {
                Spacer()
                Button(loc("Cancel")) { registering = nil }.buttonStyle(QuietButton())
                Button(loc("Register")) {
                    let target = console; registering = nil
                    Task { await remotePlay.register(console: target, pin: pin) }
                }.buttonStyle(QuietButton(prominent: true)).disabled(pin.count != 8)
            }
        }.padding(22).frame(width: 380)
    }

    @ViewBuilder private func banner(_ text: String, tint: Color = .soleAccent, action: String? = nil, perform: (() -> Void)? = nil) -> some View {
        HStack(spacing: 10) {
            Text(text).font(.system(size: 15)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let action, let perform { Button(action, action: perform).buttonStyle(QuietButton()) }
            else if perform != nil { Button { perform?() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary) }
        }.padding(13).frame(maxWidth: .infinity, alignment: .leading).background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
    }
}

struct SoleStreamPresenter: View {
    @ObservedObject var remotePlay: RemotePlay
    var body: some View {
        switch remotePlay.phase {
        case .connecting, .streaming:
            SoleStreamOverlay(remotePlay: remotePlay).transition(.opacity)
        default:
            Color.clear.frame(width: 0, height: 0)
        }
    }
}

struct StreamRoundButton: View {
    let icon: String
    let help: String
    var on = false
    var enabled = true
    var action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13, weight: .medium))
                .frame(width: StreamGlass.button, height: StreamGlass.button)
                .foregroundStyle(.white.opacity(on || hovered ? 1 : 0.75))
                .background(.white.opacity(on ? 0.2 : hovered && enabled ? 0.1 : 0), in: RoundedRectangle(cornerRadius: StreamGlass.innerRadius, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.35)
        .help(help).accessibilityLabel(help).onHover { hovered = $0 }
    }
}

struct StreamLeaveButton: View {
    var action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                Text(loc("Disconnect")).font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 8).frame(height: StreamGlass.button).foregroundStyle(.white)
            .background(hovered ? Color(red: 0.86, green: 0.25, blue: 0.27) : .clear, in: RoundedRectangle(cornerRadius: StreamGlass.innerRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovered = $0 }
    }
}

enum StreamGlass {
    static let opacity = 0.42
    static let height: CGFloat = 30
    static let radius: CGFloat = 9
    static let button: CGFloat = 24
    static let innerRadius: CGFloat = 6
    static let edge = 0.08
}

extension View {
    func streamGlass(radius: CGFloat = StreamGlass.radius, opacity: Double = StreamGlass.opacity) -> some View {
        background(Color.black.opacity(opacity), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(.white.opacity(StreamGlass.edge)))
    }
}

struct StreamStatsPanel: View {
    let stats: StreamStats
    var body: some View {
        ViewThatFits(in: .horizontal) { line(.full); line(.less); line(.least) }
            .allowsHitTesting(false)
    }
    private func line(_ detail: StreamPanel.Detail) -> some View {
        let cells = StreamPanel.cells(stats, detail: detail)
        return HStack(spacing: 12) {
            ForEach(cells.indices, id: \.self) { index in item(cells[index]) }
        }
        .lineLimit(1).fixedSize()
        .padding(.horizontal, 11).frame(height: StreamGlass.height)
        .shadow(color: .black.opacity(0.5), radius: 1.5, y: 1)
        .streamGlass()
    }
    private func item(_ cell: StreamPanel.Cell) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: cell.kind.icon).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(cell.kind == .ping ? tint(cell.trouble) : .white.opacity(0.5))
            Text(cell.value).font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
            if let unit = cell.unit { Text(unit).font(.system(size: 12)).monospacedDigit().foregroundStyle(.white.opacity(0.5)) }
        }
    }
    private func tint(_ trouble: StreamPanel.Trouble) -> Color {
        let colour = trouble.color
        return Color(red: colour.red, green: colour.green, blue: colour.blue)
    }
}

struct SoleStreamOverlay: View {
    @ObservedObject var remotePlay: RemotePlay
    @State private var loginPIN = ""
    @State private var controlsShown = true
    @State private var controlsHovered = false
    @State private var hiding: Task<Void, Never>?
    @State private var fullScreen = false
    @State private var captureHint = false

    private var connecting: Bool { if case .connecting = remotePlay.phase { return true } else { return false } }
    private var controlsVisible: Bool { (controlsShown || controlsHovered || connecting) && !remotePlay.mouseCaptured }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoSurface(view: remotePlay.surface).ignoresSafeArea()
            HStack(spacing: 8) {
                if controlsVisible { controls.transition(.opacity) }
                if remotePlay.statsVisible, let stats = remotePlay.stats { StreamStatsPanel(stats: stats).transition(.opacity) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(12).ignoresSafeArea()
            if captureHint {
                VStack {
                    Text(loc("The mouse controls the camera · ⌘ brings the pointer back"))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 1.5, y: 1)
                        .padding(.horizontal, 11).frame(height: StreamGlass.height)
                        .streamGlass()
                    Spacer()
                }.padding(12).ignoresSafeArea().transition(.opacity).allowsHitTesting(false)
            }
            if connecting {
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text(remotePlay.statusText ?? loc("Connecting…")).font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
                }
            }
            if let notice = remotePlay.trophyNotice {
                TrophyToast(notice: notice).id(notice.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(.top, 52).padding(.trailing, 16)
                    .ignoresSafeArea().allowsHitTesting(false).transition(.move(edge: .top).combined(with: .opacity))
            }
            if remotePlay.menu.isOpen {
                StreamMenuView(content: .init(menu: remotePlay.menu, game: remotePlay.streamGame, stats: remotePlay.stats, statsVisible: remotePlay.statsVisible,
                                              generation: remotePlay.frameGeneration, upscaling: remotePlay.upscaling, upscaleAmount: remotePlay.upscaleAmount, upscaleMethod: remotePlay.upscaleMethod, battery: remotePlay.controllerBattery, fullScreen: fullScreen, silentSound: remotePlay.silentSound),
                               choose: { remotePlay.choose($0) }, point: { remotePlay.pointMenu(at: $0) }, close: { remotePlay.closeMenu() })
                    .transition(.opacity.combined(with: .scale(scale: 1.03)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: remotePlay.menu.isOpen)
        .animation(.easeOut(duration: 0.3), value: remotePlay.trophyNotice)
        .onContinuousHover { phase in if case .active = phase { reveal() } }
        .onAppear {
            remotePlay.surface.onPointerActivity = { reveal() }
            reveal()
            fullScreen = remotePlay.surface.window?.styleMask.contains(.fullScreen) ?? false
        }
        .onDisappear { remotePlay.surface.onPointerActivity = nil; hiding?.cancel(); NSCursor.setHiddenUntilMouseMoves(false) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in reveal() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in fullScreen = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in fullScreen = false }
        .onChange(of: remotePlay.mouseCaptured) { _, captured in
            captureHint = captured
            if captured {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(4))
                    captureHint = false
                }
            } else {
                reveal()
            }
        }
        .animation(.easeOut(duration: 0.25), value: controlsVisible)
        .animation(.easeOut(duration: 0.25), value: captureHint)
        .animation(.easeOut(duration: 0.2), value: remotePlay.statsVisible)
        .sheet(isPresented: $remotePlay.loginPINRequest) {
            VStack(alignment: .leading, spacing: 16) {
                Text(loc("Console login code")).font(.system(size: 15, weight: .semibold))
                Text(loc("The console asked for the account login code. Enter it to continue."))
                    .font(.system(size: 15)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextField(loc("Code"), text: $loginPIN).textFieldStyle(.roundedBorder).font(.system(size: 18, design: .monospaced))
                    .onChange(of: loginPIN) { _, value in loginPIN = String(value.filter(\.isNumber).prefix(4)) }
                HStack {
                    Spacer()
                    Button(loc("Confirm")) { remotePlay.submitLoginPIN(loginPIN); loginPIN = "" }.buttonStyle(QuietButton(prominent: true))
                }
            }.padding(22).frame(width: 360)
        }
    }

    private var controls: some View {
        HStack(spacing: 2) {
            StreamLeaveButton { remotePlay.disconnect() }
            Rectangle().fill(.white.opacity(0.14)).frame(width: 1, height: 14).padding(.horizontal, 3)
            StreamRoundButton(icon: "chart.bar.fill", help: remotePlay.statsVisible ? loc("Hide stream stats") : loc("Show stream stats"), on: remotePlay.statsVisible) {
                remotePlay.statsVisible.toggle()
            }
            StreamRoundButton(icon: "square.stack.3d.forward.dottedline",
                              help: remotePlay.frameGenerationSupported ? (remotePlay.frameGeneration ? loc("Turn off frame generation") : loc("Turn on frame generation")) : loc("Frame generation is not available on this Mac"),
                              on: remotePlay.frameGeneration, enabled: remotePlay.frameGenerationSupported) {
                remotePlay.frameGeneration.toggle()
            }
            StreamRoundButton(icon: fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                              help: fullScreen ? loc("Exit full screen") : loc("Full screen")) {
                remotePlay.surface.window?.toggleFullScreen(nil)
            }
            StreamRoundButton(icon: "line.3.horizontal", help: loc("Menu")) { remotePlay.openMenu() }
        }
        .padding(.horizontal, 3).frame(height: StreamGlass.height)
        .shadow(color: .black.opacity(0.5), radius: 1.5, y: 1)
        .streamGlass()
        .fixedSize()
        .onHover { controlsHovered = $0 }
        .onDisappear { controlsHovered = false }
    }

    private func reveal() {
        controlsShown = true
        hiding?.cancel()
        hiding = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            controlsShown = false
            if !controlsHovered, !connecting, NSApp.isActive { NSCursor.setHiddenUntilMouseMoves(true) }
        }
    }
}

struct TrophyToast: View {
    let notice: TrophyNotice
    var body: some View {
        let grade = AccountPage.Grade(notice.grade).color
        let colour = Color(red: grade.red, green: grade.green, blue: grade.blue)
        HStack(spacing: 12) {
            SoleArtwork(url: notice.iconURL, maxPixels: 160) {
                ZStack { Color.white.opacity(0.06); Image(systemName: "trophy.fill").font(.system(size: 20)).foregroundStyle(colour) }
            }
            .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Label(notice.heading, systemImage: "trophy.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(colour).lineLimit(1)
                Text(notice.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(12).frame(width: 340)
        .streamGlass(radius: 2 * StreamGlass.radius, opacity: 0.62)
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
    }
}
