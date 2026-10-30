import SoleCloud
import SoleLogic
import SoleCore
import SwiftUI
import AppKit

extension Color {
    static let soleAccent = Color(red: 0.56, green: 0.71, blue: 1)
    static let soleCanvas = Color(red: 7/255, green: 10/255, blue: 20/255)
    static let soleSurface = Color.white.opacity(0.05)
    static let soleLine = Color.white.opacity(0.08)
    static func soleHue(_ hue: Double, lightness: Double = 0.42, chroma: Double = 0.11) -> Color {
        let colour = ColorWheel.rgb(hue: hue, lightness: lightness, chroma: chroma)
        return Color(red: colour.red, green: colour.green, blue: colour.blue)
    }
}
struct DesignStripes: View {
    var spacing: CGFloat = 12
    var body: some View {
        Canvas { context, size in
            for x in stride(from: -size.height, through: size.width, by: spacing) {
                var p = Path(); p.move(to: CGPoint(x: x, y: size.height)); p.addLine(to: CGPoint(x: x + size.height, y: 0))
                context.stroke(p, with: .color(.white.opacity(0.06)), lineWidth: 2)
            }
        }
    }
}
struct ConLogo: View {
    var size: CGFloat = 38
    var body: some View { Image(nsImage: ConBrand.icon).resizable().scaledToFit().frame(width: size, height: size) }
}
struct SoleAvatar<Placeholder: View>: View {
    let url: URL?; let size: CGFloat
    @ViewBuilder let placeholder: () -> Placeholder
    var body: some View { SoleArtwork(url: url, maxPixels: Int(size * 2), placeholder: placeholder).frame(width: size, height: size).clipShape(Circle()) }
}
struct QuietButton: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 15, weight: .semibold)).padding(.horizontal, 24).frame(height: 42)
            .foregroundStyle(prominent ? Color.soleCanvas : .white)
            .background(prominent ? Color.white : .white.opacity(0.12), in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
struct IconButton: View {
    let icon: String; let help: String; var action: () -> Void
    var body: some View { Button(action: action) { Image(systemName: icon).font(.system(size: 15)).frame(width: 36, height: 36).background(.white.opacity(0.08), in: Circle()) }.buttonStyle(.plain).help(help).accessibilityLabel(help).controllerTarget("icon:" + help, action: action) }
}
struct DesignWindowChrome: NSViewRepresentable {
    final class Coordinator { weak var window: NSWindow? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            if context.coordinator.window !== window {
                context.coordinator.window = window
                window.makeFirstResponder(nil)
            }
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(type)?.isHidden = true }
            window.styleMask.insert(.fullSizeContentView)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.backgroundColor = NSColor(Color.soleCanvas)
        }
    }
}
struct SoleModal<Content: View>: View {
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content
    var body: some View {
        ZStack {
            Color(red: 3/255, green: 5/255, blue: 12/255).opacity(0.55).onTapGesture(perform: onClose)
            content().clipShape(RoundedRectangle(cornerRadius: 22)).overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.soleLine)).shadow(color: .black.opacity(0.6), radius: 45, y: 30)
        }.onExitCommand(perform: onClose)
    }
}
struct SoleWindow: View {
    @EnvironmentObject private var model: SoleModel
    @EnvironmentObject private var controllerFocus: ControllerFocus
    private var screen: LibraryScreen { model.library }
    @State private var windowWidth: CGFloat = 1440
    @State private var windowHeight: CGFloat = 900
    @State private var searchExpanded = false
    @State private var catalogViewport: CGRect = .zero
    @State private var gamePageReady = false
    @FocusState private var searchFocused: Bool
    private let gridSpacing: CGFloat = 22
    private let gridInset: CGFloat = 48
    private let minimumCard: CGFloat = 180
    private var columnCount: Int { max(2, min(6, Int((windowWidth - gridInset + gridSpacing) / (minimumCard + gridSpacing)))) }
    private var visibleGameCount: Int { screen.visibleRows * columnCount }
    private var game: Game? { screen.game }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.soleCanvas
                HiddenUnderStream(remotePlay: model.remotePlay) {
                    design.frame(width: geometry.size.width, height: geometry.size.height).id(model.language)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { windowWidth = geometry.size.width; windowHeight = geometry.size.height }
                .onChange(of: geometry.size) { _, size in windowWidth = size.width; windowHeight = size.height }
        }.ignoresSafeArea(.container, edges: .top).background(DesignWindowChrome()).background(DesignControllerInput(yields: { [remotePlay = model.remotePlay] in remotePlay.phase.isLive }) { action in
            screen.gamepad(action)
        }).background(DesignKeyboard { key, text in
            screen.key(MacKeys.usages[key], text: text)
        }).preferredColorScheme(.dark).tint(.soleAccent)
            .onPreferenceChange(ControllerTargets.self) { controllerFocus.update($0) }
            .onChange(of: model.settingsOpen) { _, open in screen.settingsChanged(open: open) }
            .onChange(of: model.gameOpen) { _, open in
                screen.gamePageChanged(open: open)
                gamePageReady = false
                if open { Task { @MainActor in try? await Task.sleep(for: .milliseconds(350)); gamePageReady = true } }
            }
            .task { model.reloadCatalog(); await model.restoreAccount() }
            .onChange(of: model.connectingCloud) { _, connecting in screen.connectingChanged(connecting) }
            .onChange(of: model.search) { _, _ in screen.startOver() }
            .onChange(of: model.filter) { _, _ in screen.startOver() }
            .onChange(of: model.catalogBackend) { _, _ in screen.catalogReplaced() }
            .onChange(of: columnCount, initial: true) { _, count in screen.columns = count }
            .sheet(isPresented: $model.loginOpen) { SoleLogin().environmentObject(model) }
            .alert("Con", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) { Button(loc("OK")) { model.message = nil } } message: { Text(model.message ?? "") }
            .background(DesignStreamLifecycle(remotePlay: model.remotePlay) { screen.launching = false })
            .overlay { SoleStreamPresenter(remotePlay: model.remotePlay) }
            .environmentObject(controllerFocus)
    }
    private var design: some View {
        ZStack {
            if !gamePageOpen {
                VStack(spacing: 0) {
                    header
                    if windowWidth < 850, searchExpanded, model.destination == .cloud {
                        searchField.frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.bottom, 12)
                    }
                    if model.destination == .cloud { library } else { consoles }
                }.blur(radius: backdropBlur).disabled(model.settingsOpen || screen.launching || gamePageOpen).accessibilityHidden(model.settingsOpen || screen.launching || gamePageOpen)
            }
            if gamePageOpen, let game {
                gamePage(game).blur(radius: backdropBlur).disabled(model.settingsOpen || screen.launching).accessibilityHidden(model.settingsOpen || screen.launching).transition(.opacity)
            }
            VStack { Spacer(); footer }.allowsHitTesting(false)
            if model.settingsOpen { SoleModal(onClose: { model.settingsOpen = false }) { SoleSettings(onClose: { model.settingsOpen = false }, width: min(1000, windowWidth - 40), height: min(640, windowHeight - 40)) }.transition(.opacity) }
            if screen.launching { launchOverlay }
            ControllerChoices()
            PadKeyboardView(width: windowWidth)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { background }
            .foregroundStyle(Color(red: 244/255, green: 246/255, blue: 251/255)).clipped()
            .animation(.easeInOut(duration: 0.3), value: model.settingsOpen)
            .animation(.easeOut(duration: 0.2), value: controllerFocus.keyboard != nil)
            .onChange(of: model.gameOpen) { _, open in if open { controllerFocus.closeKeyboard() } }
            .onChange(of: model.settingsOpen) { _, open in if open { controllerFocus.closeKeyboard() } }
            .onChange(of: model.connectingCloud) { _, connecting in if connecting { controllerFocus.closeKeyboard() } }
            .animation(.easeInOut(duration: 0.25), value: gamePageOpen)
    }
    private var gamePageOpen: Bool { model.gameOpen && model.destination == .cloud }
    private var backdropBlur: CGFloat { model.settingsOpen ? 18 : screen.launching ? 30 : 0 }
    private var background: some View {
        ZStack {
            Color.soleCanvas
            RadialGradient(colors: [Color.soleHue(game?.hue ?? 100, lightness: 0.45, chroma: 0.16).opacity(0.75), .clear], center: UnitPoint(x: 0.8, y: 0), startRadius: 0, endRadius: 850)
            RadialGradient(colors: [Color.soleHue((game?.hue ?? 100) + 40, lightness: 0.32, chroma: 0.12).opacity(0.5), .clear], center: UnitPoint(x: 0.05, y: 0.9), startRadius: 0, endRadius: 700)
            LinearGradient(colors: [.clear, Color.soleCanvas.opacity(0.55), Color.soleCanvas.opacity(0.9)], startPoint: .top, endPoint: .bottom)
        }.animation(.easeInOut(duration: 0.2), value: game?.id)
    }
    private var header: some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) { ConLogo(); Text("Con").font(.system(size: 20, weight: .semibold)) }.padding(.trailing, windowWidth < 1120 ? 16 : 36)
            if windowWidth >= 1120, Destination.consolesShown { HStack(spacing: 28) {
                navigation(loc("Cloud games"), selected: model.destination == .cloud) { model.destination = .cloud }
                navigation(loc("My consoles"), selected: model.destination == .consoles) { model.destination = .consoles }
            } }
            Spacer()
            if model.destination == .cloud {
                if windowWidth >= 850 {
                    searchField.frame(width: windowWidth < 1250 ? 200 : 268).padding(.trailing, 14)
                } else {
                    IconButton(icon: "magnifyingglass", help: loc("Search games")) { searchExpanded.toggle() }.padding(.trailing, 12)
                }
                if windowWidth >= 1120 {
                    IconButton(icon: "arrow.clockwise", help: loc("Refresh library")) { refreshLibrary() }.padding(.trailing, 14)
                }
            }
            if windowWidth < 1120 {
                Menu {
                    if !destinationChoices.isEmpty {
                        ForEach(destinationChoices.indices, id: \.self) { index in Button(destinationChoices[index].title, action: destinationChoices[index].action) }
                        Divider()
                    }
                    ForEach(appChoices.indices, id: \.self) { index in Button(appChoices[index].title, action: appChoices[index].action) }
                } label: { Image(systemName: "line.3.horizontal").font(.system(size: 18)).frame(width: 36, height: 36).background(.white.opacity(0.08), in: Circle()) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().padding(.trailing, 12).controllerTarget("header-menu") {
                        controllerFocus.choiceIndex = 0
                        controllerFocus.choices = destinationChoices + appChoices
                    }
            }
            if windowWidth >= 1120 { IconButton(icon: "gearshape", help: loc("Settings")) { model.showSettings() }.padding(.trailing, 22) }
            Button { model.showSettings(.account) } label: {
                HStack(spacing: 10) {
                    SoleAvatar(url: model.account?.avatarURL, size: 36) { Color(red: 42/255, green: 47/255, blue: 69/255).overlay(DesignStripes()) }.overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 2)).overlay(alignment: .bottomTrailing) { Circle().fill(model.account == nil ? .gray : .green).frame(width: 10, height: 10).overlay(Circle().stroke(Color.soleCanvas, lineWidth: 2)) }
                    if windowWidth >= 1300 { VStack(alignment: .leading, spacing: 3) { Text(model.account?.displayName ?? "PlayStation").font(.system(size: 13, weight: .semibold)); Text(model.account == nil ? loc("Sign in") : loc("Connected")).font(.system(size: 11)).opacity(0.55) } }
                }
            }.buttonStyle(.plain).controllerTarget("account") { model.showSettings(.account) }
        }.padding(.leading, 100).padding(.trailing, 24).frame(height: 76).overlay(alignment: .leading) { windowButtons }
    }
    private var destinationChoices: [FocusModel.Choice] { screen.destinationChoices }
    private var appChoices: [FocusModel.Choice] { screen.appChoices() }
    private func refreshLibrary() {
        model.reloadCatalog(force: true)
        model.reloadLibrary()
    }
    private var windowButtons: some View {
        HStack(spacing: 8) {
            traffic(.red) { NSApp.keyWindow?.performClose(nil) }
            traffic(.yellow) { NSApp.keyWindow?.miniaturize(nil) }
            traffic(.green) { NSApp.keyWindow?.toggleFullScreen(nil) }
        }.padding(.leading, 24)
    }
    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").font(.system(size: 15)).opacity(0.6)
            TextField(loc("Search games"), text: $model.search).textFieldStyle(.plain).font(.system(size: 14)).focused($searchFocused)
        }.padding(.horizontal, 14).frame(height: 36).background(.white.opacity(0.08), in: Capsule()).overlay(Capsule().stroke(.white.opacity(0.08))).controllerTarget(LibraryScreen.Target.search) {
            guard screen.fromGamepad else { searchFocused = true; return }
            screen.typeSearch()
        }
    }
    private func traffic(_ color: Color, action: @escaping () -> Void) -> some View { Button(action: action) { Circle().fill(color).frame(width: 12, height: 12) }.buttonStyle(.plain) }
    private func navigation(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.system(size: 16, weight: .medium)).opacity(selected ? 1 : 0.55).padding(.horizontal, 6).padding(.vertical, 10).contentShape(Rectangle()) }.buttonStyle(.plain).controllerTarget("nav:" + title, action: action).frame(height: 76)
    }
    private var library: some View {
        VStack(spacing: 0) {
            Group {
                if windowWidth < 1050 {
                    VStack(alignment: .leading, spacing: 14) { catalogHeading; catalogFilters }
                } else {
                    HStack { catalogHeading; Spacer(); catalogFilters }
                }
            }.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 4)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: 1).id("libraryTop")
                        VStack(alignment: .leading, spacing: 24) {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: columnCount), spacing: gridSpacing) { ForEach(model.orderedGames.prefix(visibleGameCount)) { SoleGameCard(game: $0).id($0.id) } }
                            if model.filteredGames.isEmpty { Text(screen.emptyText).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(40) }
                            if model.orderedGames.count > visibleGameCount { Button(loc("Show more")) { screen.showMore() }.buttonStyle(QuietButton()).controllerTarget(LibraryScreen.Target.more) { screen.showMore() }.frame(maxWidth: .infinity).id("more-games") }
                            if let error = model.catalogError ?? model.pcCatalogError ?? model.libraryError { Text(error).font(.system(size: 13)).foregroundStyle(.secondary) }
                        }.padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 90)
                    }
                }.scrollIndicators(.hidden)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: CatalogViewport.self, value: geometry.frame(in: .global))
                    }
                }
                .onPreferenceChange(CatalogViewport.self) { catalogViewport = $0 }
                .onChange(of: controllerFocus.selected) { _, id in
                    guard !model.gameOpen, !model.settingsOpen, let id else { return }
                    if id == LibraryScreen.Target.more {
                        withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: UnitPoint(x: 0.5, y: 0.85)) }
                        return
                    }
                    guard id.hasPrefix(LibraryScreen.Target.gamePrefix), let index = model.orderedGames.firstIndex(where: { LibraryScreen.Target.game($0.id) == id }) else { return }
                    if index < columnCount {
                        withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo("libraryTop", anchor: .top) }
                        return
                    }
                    let cardSize = (windowWidth - gridInset - CGFloat(columnCount - 1) * gridSpacing) / CGFloat(columnCount)
                    let headerHeight: CGFloat = windowWidth < 1050 ? 80 : 40
                    let viewportHeight = catalogViewport.height > 0 ? catalogViewport.height : windowHeight - 76 - headerHeight - 16
                    let margin = cardSize * 0.03 + 9
                    let row = index / columnCount
                    let contentBottom = 21 + CGFloat(row) * (cardSize + gridSpacing) + cardSize
                    let target = controllerFocus.targets.first(where: { $0.id == id })
                    let clipped: Bool
                    let revealingTop: Bool
                    if let target, catalogViewport.height > cardSize {
                        revealingTop = target.rect.minY < catalogViewport.minY + margin
                        clipped = revealingTop || target.rect.maxY > catalogViewport.maxY - 44 - margin
                    } else {
                        revealingTop = false
                        clipped = contentBottom > viewportHeight - 44 - margin
                    }
                    guard clipped else { return }
                    let space = max(1, viewportHeight - cardSize)
                    let y = revealingTop ? margin / space : 1 - (44 + margin) / space
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(model.orderedGames[index].id, anchor: UnitPoint(x: 0.5, y: min(1, max(0, y))))
                    }
                }
            }
        }
    }
    private var catalogHeading: some View {
        HStack(spacing: windowWidth < 760 ? 10 : 20) { catalogTitle; catalogSources }
    }
    private var catalogTitle: some View {
        HStack(spacing: 12) {
            Text(loc("Cloud catalog")).font(.system(size: windowWidth < 760 ? 14 : 18, weight: .semibold)).lineLimit(1)
            if windowWidth >= 760 { Text(loc("%@ games", model.filteredGames.count)).font(.system(size: 14)).opacity(0.5) }
        }
    }
    private var catalogSources: some View {
        HStack(spacing: 8) {
            ForEach([CloudBackend.ps5, .psPlusPC, .ps3], id: \.rawValue) { backend in
                Button { model.catalogBackend = backend } label: {
                    Text(backend.console)
                        .font(.system(size: windowWidth < 760 ? 12 : 14, weight: .semibold)).lineLimit(1).padding(.horizontal, windowWidth < 760 ? 10 : 16).padding(.vertical, 7)
                        .foregroundStyle(model.catalogBackend == backend ? Color.soleCanvas : .white.opacity(0.7))
                        .background(model.catalogBackend == backend ? .white : .white.opacity(0.07), in: Capsule())
                }.buttonStyle(.plain).controllerTarget("catalog-source:" + backend.rawValue) { model.catalogBackend = backend }
            }
        }.fixedSize(horizontal: true, vertical: false)
    }
    private var catalogFilters: some View {
        HStack(spacing: 0) {
            ForEach(model.availableLibraryFilters, id: \.self) { filter in
                Button { model.filter = filter } label: {
                    Text(loc(filter.rawValue)).font(.system(size: 13)).padding(.horizontal, 16).frame(height: 30)
                        .foregroundStyle(model.filter == filter ? Color.soleCanvas : .white.opacity(0.75))
                        .background(model.filter == filter ? .white : .clear, in: Capsule())
                }.buttonStyle(.plain).controllerTarget(LibraryScreen.Target.filter(filter)) { model.filter = filter }
            }
        }.padding(4).background(.white.opacity(0.07), in: Capsule())
    }
    private func gamePage(_ game: Game) -> some View {
        let narrow = windowWidth < 900
        let compactActions = windowWidth < 1100
        let thumbnailHeight = max(100, min(220, windowHeight * 0.26))
        let heroHeight = max(120, windowHeight - 96 - 60 - 24 - thumbnailHeight - 54)
        let cover = min(min(narrow ? 160 : 320, heroHeight), windowWidth * 0.24)
        let details = VStack(alignment: .leading, spacing: 0) {
            Text(([game.platform] + game.genres.prefix(1).map(Game.genreName)).joined(separator: " · ").uppercased()).font(.system(size: 13, weight: .semibold)).tracking(0.8).opacity(0.7)
            Text(game.title).font(.system(size: narrow ? 28 : 44, weight: .bold)).tracking(-1).lineLimit(2).minimumScaleFactor(0.6).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            HStack(spacing: 12) {
                Button { screen.play(game) } label: { HStack(spacing: 10) { Image(systemName: "play.fill").font(.system(size: 14)); Text(loc("Play")).font(.system(size: 16, weight: .semibold)) }.padding(.horizontal, 34).frame(height: 48).foregroundStyle(Color.soleCanvas).background(.white, in: Capsule()) }.buttonStyle(.plain).controllerTarget(LibraryScreen.Target.pagePlay) { screen.play(game) }
                Button { model.toggleFavorite(game.id) } label: { HStack(spacing: 8) { Image(systemName: game.favorite ? "star.fill" : "star"); if !compactActions { Text(game.favorite ? loc("In favorites") : loc("Add to favorites")) } }.font(.system(size: 15, weight: .medium)).padding(.horizontal, 20).frame(height: 48).background(.white.opacity(0.12), in: Capsule()) }.buttonStyle(.plain).controllerTarget("page-favorite") { model.toggleFavorite(game.id) }
                if let url = game.storeURL {
                    Button { NSWorkspace.shared.open(url) } label: { HStack(spacing: 8) { Image(systemName: "arrow.up.right"); if !compactActions { Text(loc("PS Store")) } }.font(.system(size: 15, weight: .medium)).padding(.horizontal, 20).frame(height: 48).background(.white.opacity(0.12), in: Capsule()) }.buttonStyle(.plain).controllerTarget("page-store") { NSWorkspace.shared.open(url) }
                }
            }.padding(.top, 26).allowsHitTesting(gamePageReady)
        }
        return ZStack {
            SoleGameBackdrop(game: game)
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .center, spacing: narrow ? 24 : 44) {
                    SoleGameCover(game: game).frame(width: cover, height: cover).shadow(color: .black.opacity(0.5), radius: 20, y: 12)
                    details.frame(maxWidth: .infinity, alignment: .leading)
                }
                SoleGameGallery(game: game, thumbnailHeight: thumbnailHeight, availableWidth: windowWidth - (narrow ? 48 : 128))
            }.padding(.horizontal, narrow ? 24 : 64).padding(.top, 96).padding(.bottom, 60)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
            .overlay(alignment: .topLeading) {
                HStack(spacing: 0) {
                    windowButtons
                    Button { model.gameOpen = false } label: { Label(loc("Catalog"), systemImage: "chevron.left").font(.system(size: 14, weight: .medium)).padding(.horizontal, 16).frame(height: 36).background(.white.opacity(0.1), in: Capsule()) }.buttonStyle(.plain).padding(.leading, 24).controllerTarget("page-back") { model.gameOpen = false }
                }.frame(height: 76)
            }
    }
    private var consoles: some View {
        HStack(alignment: .top, spacing: 60) {
            VStack(alignment: .leading, spacing: 12) {
                Text(loc("Your PlayStation. Right here.")).font(.system(size: windowWidth < 850 ? 36 : 52, weight: .bold)).tracking(-1.3)
                Text(loc("Connect to your console and pick up where you left off.")).font(.system(size: 18)).opacity(0.7)
                SoleConsoles(remotePlay: model.remotePlay).padding(.top, 42)
            }
            if windowWidth >= 1050 { TimelineView(.animation) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                ZStack {
                    ForEach(0..<3) { i in let phase = (time + Double(i)*1.2).truncatingRemainder(dividingBy: 3.6)/3.6; Circle().stroke(Color.soleAccent.opacity((1-phase)*0.55)).frame(width: 180, height: 180).scaleEffect(0.4+phase*2) }
                    Circle().fill(.white.opacity(0.1)).frame(width: 92, height: 92).overlay(Circle().stroke(.white.opacity(0.15))).overlay(Image(systemName: "gamecontroller").font(.system(size: 40)))
                }.frame(width: 420, height: 420)
            } }
        }.padding(.horizontal, 24).padding(.top, windowWidth < 850 ? 32 : 80).frame(maxHeight: .infinity, alignment: .top)
    }
    private var footer: some View {
        HStack(spacing: 22) {
            Spacer()
            if windowWidth >= 850 { hint("↑ ↓ ← →", loc("Navigate")); hint("↵", gamePageOpen ? loc("Play") : loc("Open")); hint("F", loc("Favorites")); hint("esc", gamePageOpen ? loc("Back") : loc("Close")) }
        }.font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).padding(.horizontal, 24).frame(height: 44).background(LinearGradient(colors: [.clear, Color.soleCanvas.opacity(0.95)], startPoint: .top, endPoint: .bottom))
    }
    private func hint(_ key: String, _ title: String) -> some View { HStack(spacing: 6) { Text(key).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 1).background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 4)); Text(title) } }
    private var launchOverlay: some View {
        ZStack {
            Color.soleCanvas.opacity(0.82)
            VStack(spacing: 0) {
                if let game { SoleGameCover(game: game).frame(width: 220, height: 220).shadow(color: .black.opacity(0.6), radius: 40, y: 30); Text(game.title).font(.system(size: 28, weight: .semibold)).padding(.top, 34) }
                Text(model.cloudError ?? model.cloudStatus ?? loc("Checking access to the game…")).font(.system(size: 15)).opacity(0.7).multilineTextAlignment(.center).frame(maxWidth: 640).padding(.top, 12)
                if model.connectingCloud { ProgressView().progressViewStyle(.linear).frame(width: 320).padding(.top, 22) }
                Button(model.connectingCloud ? loc("Cancel") : loc("Close")) { screen.cancelLaunch() }.buttonStyle(QuietButton()).controllerTarget(LibraryScreen.Target.launchCancel) { screen.cancelLaunch() }
                    .padding(.top, 34)
            }
        }.onExitCommand { screen.cancelLaunch() }
    }
}

struct DesignKeyboard: NSViewRepresentable {
    var handle: (UInt16, String) -> Bool
    final class Coordinator {
        var handle: (UInt16, String) -> Bool
        var monitor: Any?
        init(handle: @escaping (UInt16, String) -> Bool) { self.handle = handle }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
    func makeCoordinator() -> Coordinator { Coordinator(handle: handle) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator = context.coordinator, weak view] event in
            guard event.window == view?.window, event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let coordinator else { return event }
            if event.window?.firstResponder is NSTextView { return event }
            return coordinator.handle(event.keyCode, event.charactersIgnoringModifiers ?? "") ? nil : event
        }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.handle = handle }
}

struct DesignSelect<Value: Hashable>: View {
    @EnvironmentObject private var focus: ControllerFocus
    @Binding var selection: Value
    let values: [(Value, String)]
    let label: String
    var width: CGFloat = 200
    var identifier: String? = nil
    private var targetID: String { "select:" + (identifier ?? label) }
    private func openChoices() {
        guard !values.isEmpty else { return }
        focus.selected = targetID
        focus.choiceIndex = values.firstIndex { $0.0 == selection } ?? 0
        focus.choices = values.map { value in .init(title: value.1, action: { selection = value.0 }) }
    }
    var body: some View {
        Button(action: openChoices) {
            HStack { Text(values.first(where: { $0.0 == selection })?.1 ?? label).lineLimit(1); Spacer(minLength: 8); Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).opacity(0.65) }
                .font(.system(size: 14)).foregroundStyle(.white).padding(.horizontal, 12).frame(width: width, height: 36).background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).accessibilityLabel(label).accessibilityValue(values.first(where: { $0.0 == selection })?.1 ?? "")
            .controllerTarget(targetID, action: openChoices)
    }
}
struct FlowRows: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }
    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var y: CGFloat = 0; var height: CGFloat = 0 }
    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [], row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !row.indices.isEmpty, row.width + spacing + size.width > width {
                rows.append(row)
                row = Row(y: row.y + row.height + spacing)
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

struct DesignToggle: View {
    @Binding var isOn: Bool
    let label: String
    var body: some View {
        Button { isOn.toggle() } label: {
            Capsule().fill(isOn ? Color.soleAccent : .white.opacity(0.18)).frame(width: 48, height: 28)
                .overlay(alignment: .leading) { Circle().fill(.white).frame(width: 22, height: 22).offset(x: isOn ? 23 : 3) }
        }.buttonStyle(.plain).controllerTarget("toggle:" + label) { isOn.toggle() }.animation(.spring(response: 0.3), value: isOn).accessibilityLabel(label).accessibilityValue(isOn ? loc("On") : loc("Off"))
    }
}

struct DesignStreamLifecycle: View {
    @ObservedObject var remotePlay: RemotePlay
    let onStarted: () -> Void
    var body: some View {
        Color.clear.frame(width: 0, height: 0).onChange(of: remotePlay.phase) { _, phase in
            if phase.isLive { onStarted() }
        }
    }
}

struct SoleGameBackdrop: View {
    let game: Game
    var body: some View {
        GeometryReader { geometry in
            SoleArtwork(url: game.artworkURL, maxPixels: 640) { Color.soleHue(game.hue, lightness: 0.4, chroma: 0.12) }.frame(width: geometry.size.width, height: geometry.size.height).clipped().blur(radius: 50, opaque: true)
                .overlay(Color.soleCanvas.opacity(0.45))
                .overlay(LinearGradient(colors: [Color.soleCanvas.opacity(0.2), Color.soleCanvas.opacity(0.9)], startPoint: .top, endPoint: .bottom))
        }.clipped()
    }
}

private struct CatalogViewport: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

private struct HiddenUnderStream<Content: View>: View {
    @ObservedObject var remotePlay: RemotePlay
    @ViewBuilder var content: Content
    var body: some View {
        let live: Bool = { if case .streaming = remotePlay.phase { return true } else { return false } }()
        content.opacity(live ? 0 : 1).allowsHitTesting(!live)
    }
}
