import SwiftUI
import SoleLogic
import SoleCore
import SoleMedia
import AppKit

struct SoleSettings: View {
    @EnvironmentObject private var model: SoleModel
    @EnvironmentObject private var focus: ControllerFocus
    @AppStorage(Smoothness.key) private var presentationLead = Smoothness.read(.standard)
    @AppStorage(RemotePlay.frameGenerationKey) private var frameGeneration = false
    @AppStorage(RemotePlay.upscalingKey) private var upscaling = false
    @AppStorage(Upscale.methodKey) private var upscaleMethod = Upscale.Method.fsr.rawValue
    @AppStorage(Upscale.amountKey) private var upscaleAmount = Upscale.Amount.double.rawValue
    @AppStorage(RemotePlay.generationHeightKey) private var generationHeight = VideoPipeline.defaultGenerationHeight
    let onClose: () -> Void
    var width: CGFloat = 1000
    var height: CGFloat = 640
    var body: some View {
        Group {
            if width < 820 {
                VStack(spacing: 0) {
                    FlowRows(spacing: 8) {
                        ForEach(SettingsSection.allCases) { section in
                            Button { model.settingsSection = section } label: {
                                Text(loc(section.rawValue)).font(.system(size: 14, weight: .medium)).lineLimit(1).padding(.horizontal, 14).frame(height: 38)
                                    .foregroundStyle(model.settingsSection == section ? Color.soleCanvas : .white)
                                    .background(model.settingsSection == section ? .white : .white.opacity(0.07), in: Capsule())
                            }.buttonStyle(.plain).controllerTarget(LibraryScreen.Target.settingsTab(section)) { model.settingsSection = section }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 4)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(loc(model.settingsSection.rawValue)).font(.system(size: 24, weight: .semibold))
                            Spacer()
                            IconButton(icon: "xmark", help: loc("Close settings")) { onClose() }.keyboardShortcut(.cancelAction)
                        }.padding(.bottom, 20).padding(.horizontal, 10)
                        sectionContent
                    }.padding(.horizontal, width < 760 ? 10 : 30).padding(.vertical, 30).frame(maxWidth: .infinity)
                }
            } else {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(loc("Settings")).font(.system(size: 20, weight: .semibold)).padding(.leading, 12).padding(.bottom, 22)
                        ForEach(SettingsSection.allCases) { section in
                            Button { model.settingsSection = section } label: {
                                HStack(spacing: 10) {
                                    Text(loc(section.rawValue)).lineLimit(1)
                                    Spacer()
                                }.font(.system(size: 15, weight: model.settingsSection == section ? .medium : .regular))
                                    .padding(.horizontal, 14).frame(height: 44)
                                    .background(model.settingsSection == section ? Color.white : .clear, in: RoundedRectangle(cornerRadius: 12))
                                    .foregroundStyle(model.settingsSection == section ? Color(red: 0.10, green: 0.12, blue: 0.18) : Color.primary)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).controllerTarget(LibraryScreen.Target.settingsTab(section)) { model.settingsSection = section }
                        }
                        Spacer()
                        Text("Con · \(ConBrand.version)").font(.system(size: 13))
                            .foregroundStyle(.secondary).padding(.leading, 10)
                    }.padding(.horizontal, 18).padding(.vertical, 30).frame(width: 220).background(Color.primary.opacity(0.025))
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(loc(model.settingsSection.rawValue)).padding(.trailing, 40).font(.system(size: 24, weight: .semibold))
                            Spacer()
                        }.padding(.bottom, 26).padding(.horizontal, 10)
                        sectionContent
                    }.padding(.horizontal, width < 760 ? 10 : 30).padding(.vertical, 30).frame(maxWidth: .infinity)
                }
            }
        }.frame(width: width, height: height).overlay(alignment: .topTrailing) {
            if width >= 820 { IconButton(icon: "xmark", help: loc("Close settings")) { onClose() }.keyboardShortcut(.cancelAction).padding(.trailing, 20).padding(.top, 24) }
        }.background(Color(red: 18/255, green: 21/255, blue: 34/255)).tint(.soleAccent)
    }
    private var sectionContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: model.settingsSection == .general ? 0 : 20) {
                    switch model.settingsSection {
                    case .general: general
                    case .account: account
                    case .stream: stream
                    case .controller: controller
                    case .about: about
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10).padding(.bottom, 16).padding(.horizontal, 10)
            }.scrollIndicators(.hidden).onChange(of: focus.selected) { _, id in
                guard let id, !id.hasPrefix(LibraryScreen.Target.settingsTabPrefix), !id.hasPrefix("icon:") else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
    private var general: some View {
        Group {
            settingRow(loc("App language"), caption: loc("The language of Con's interface")) {
                DesignSelect(selection: $model.language, values: AppLanguage.allCases.map { ($0.rawValue, $0.name) }, label: loc("App language"), identifier: "app-language")
            }
            settingRow(loc("Catalog region"), caption: loc("Sony's list of games · not the datacenter choice")) {
                DesignSelect(selection: $model.catalogLocale, values: CatalogRegion.choices, label: loc("Catalog region")).onChange(of: model.catalogLocale) { _, _ in model.reloadCatalog() }
            }
            settingRow(loc("Picture size"), caption: loc("How the video fills the window"), last: true) {
                DesignSelect(selection: $model.videoFit, values: [("fit", loc("Fit")), (AppModel.fill, loc("Fill"))], label: loc("Picture size"))
            }
        }
    }
    private var account: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 15) {
                SoleAvatar(url: model.account?.avatarURL, size: 64) {
                    Image(systemName: "person.crop.circle.fill").font(.system(size: 48, weight: .light)).foregroundStyle(Color.white)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.account?.displayName ?? loc("Your PlayStation account")).font(.system(size: 20, weight: .semibold))
                    Text(model.restoringAccount ? loc("Restoring your saved sign-in…") : model.account == nil ? loc("Sign in to open your game library.") : loc("Account connected")).font(.system(size: 14)).foregroundStyle(.secondary)
                }
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(Color.soleSurface, in: RoundedRectangle(cornerRadius: 16))
            HStack(spacing: 12) {
                if model.account != nil {
                    Button(loc("Refresh sign-in")) { openLogin() }.buttonStyle(QuietButton(prominent: true)).controllerTarget("account-refresh") { openLogin() }
                }
                Button(model.restoringAccount ? loc("Restoring sign-in…") : model.account == nil ? loc("Connect account") : loc("Sign out")) {
                    if model.account != nil { model.signOut() } else { openLogin() }
                }.buttonStyle(QuietButton(prominent: model.account == nil)).foregroundStyle(model.account == nil ? Color.soleCanvas : Color(red: 1, green: 0.54, blue: 0.5)).disabled(model.restoringAccount || model.signingOut).controllerTarget("account-login") { if model.account != nil { model.signOut() } else { openLogin() } }
            }
            if model.account == nil, !model.restoringAccount, let error = model.authError {
                Text(error).font(.system(size: 15)).foregroundStyle(Color.soleAccent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(loc("You sign in on the PlayStation page. Con never asks for your password in forms of its own."))
                .font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
            SoleAccountPage(page: AccountPage(model), narrow: width < 820) { model.library.openRecent($0) }
        }
    }
    private var stream: some View {
        Group {
            VStack(alignment: .leading, spacing: 12) {
                sectionLabel(loc("Video quality"))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: width < 650 ? 2 : width < 900 ? 3 : 6), spacing: 10) {
                    ForEach(StreamQuality.heights, id: \.self) { resolution in
                        Button { model.selectPreset(resolution) } label: {
                            VStack(spacing: 5) {
                                Text(StreamQuality.name(height: resolution)).font(.system(size: 17, weight: .bold))
                                Text(StreamQuality.note(height: resolution))
                                    .lineLimit(1).minimumScaleFactor(0.8)
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity).frame(height: 72)
                                .background(model.resolution == resolution ? Color.white.opacity(0.1) : Color.soleSurface, in: RoundedRectangle(cornerRadius: 14))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(model.resolution == resolution ? Color.white : Color.soleLine, lineWidth: 2))
                        }.buttonStyle(.plain).controllerTarget("quality:\(resolution)") { model.selectPreset(resolution) }
                    }
                }
            }
            settingRow(loc("Bitrate"), caption: loc("Higher means more detail and more data used")) {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(loc("%@ Mbps", Int(model.bitrate))).font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
                    Slider(value: $model.bitrate, in: StreamQuality.lowestBitrate...StreamQuality.highestBitrate, step: 1).frame(width: min(260, width - 80)).controllerTarget("bitrate", adjust: { model.bitrate = StreamQuality.clampedBitrate(model.bitrate + Double($0)) }) {}
                }
            }
            settingRow(loc("Smooth presentation"), caption: loc("How long a frame waits for an even rhythm. Less is sooner on screen, but less even on an uneven network")) {
                DesignSelect(selection: $presentationLead, values: Smoothness.choices(byRefresh: true), label: loc("Smooth presentation"))
            }
            if VideoPipeline.generationSupported {
                settingRow(loc("Frame generation"), caption: loc("A frame between two frames of the game when the display can show it. Adds delay")) {
                    DesignToggle(isOn: $frameGeneration, label: loc("Frame generation"))
                }
                settingRow(loc("Generation resolution"), caption: loc("The size the generated frame is computed at. Higher is sharper but slower: for powerful Macs")) {
                    DesignSelect(selection: $generationHeight, values: generationHeights, label: loc("Generation resolution"))
                }
            } else {
                settingRow(loc("Frame generation"), caption: loc("Frame generation is not available on this Mac")) {
                    DesignToggle(isOn: .constant(false), label: loc("Frame generation")).disabled(true).opacity(0.4)
                }
            }
            settingRow(loc("Upscaler"), caption: loc("Enlarges the picture to the size of the window while keeping it sharp, when the stream is smaller than the screen. Puts a little load on the graphics card")) {
                DesignToggle(isOn: $upscaling, label: loc("Upscaler"))
            }
            if upscaling {
                settingRow(loc("Upscaling method"), caption: loc("FSR 1 — sharp edges with almost no delay; Anime4K — a neural network that adds detail; MetalFX — Apple's way, slower")) {
                    DesignSelect(selection: $upscaleMethod, values: [Upscale.Method.fsr, .anime4k, .metalFX].map { ($0.rawValue, $0.title) }, label: loc("Upscaling method"))
                }
                settingRow(loc("Enlargement"), caption: loc("By how much to enlarge the stream. More is sharper but slower")) {
                    DesignSelect(selection: $upscaleAmount, values: Upscale.Amount.allCases.map { ($0.rawValue, $0.title) }, label: loc("Enlargement"))
                }
            }
            settingRow(loc("Trophy notifications"), caption: loc("Show trophies earned over the game")) {
                DesignToggle(isOn: $model.trophyNotices, label: loc("Trophy notifications"))
            }
            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 10) {
                settingRow(loc("Datacenter"), caption: model.datacenterCaption) {
                    DesignSelect(selection: $model.selectedDatacenter, values: model.datacenterChoices, label: loc("Datacenter"), width: 260).disabled(model.datacenters.isEmpty)
                }
                settingRow(loc("Distant servers"), caption: loc("Reports a lower latency to Sony so that a server further than 80 ms is accepted. This breaks Sony's rules: at your own risk")) {
                    DesignToggle(isOn: $model.distantServers, label: loc("Distant servers"))
                }
                Text(model.datacenterNote)
                    .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if model.cloudCanRetry, model.account != nil {
                    Button(loc("Connect again")) { model.connectCloud() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Color.soleAccent)
                }
            }
            Divider().opacity(0.4)
            settingRow(loc("Game language"), caption: loc("If the game supports it")) {
                DesignSelect(selection: $model.gameLanguage, values: GameLanguage.all.map { ($0.code, $0.name) }, label: loc("Game language"))
            }
        }
    }
    private var generationHeights: [(Int, String)] {
        GenerationState.heightChoices(offered: VideoPipeline.generationHeights, chosen: generationHeight).map { ($0.height, $0.title) }
    }
    private var controller: some View {
        Group {
            SoleControllers()
            SoleKeyboardSettings()
            SoleMouseSettings()
            settingRow(loc("Vibration"), caption: loc("Feedback in games that support it")) {
                DesignToggle(isOn: $model.haptics, label: loc("Vibration"))
            }
        }
    }
    private var about: some View {
        VStack(alignment: .leading, spacing: 16) {
            ConLogo(size: 84)
            Text("Con").font(.system(size: 40, weight: .semibold))
            Text(loc("Your games. Your Mac.")).font(.system(size: 18)).foregroundStyle(.secondary)
            Text(loc("Version %@", ConBrand.version)).font(.system(size: 13)).foregroundStyle(.tertiary)
            Divider().padding(.vertical, 5)
            Text(loc("Cloud games and connection to your PlayStation."))
                .font(.system(size: 14)).foregroundStyle(.secondary)
            Button(loc("Licenses")) { openLicenses() }
                .buttonStyle(.plain).font(.system(size: 14)).foregroundStyle(Color.soleAccent)
                .controllerTarget("about-licenses") { openLicenses() }
        }
    }
    private func openLicenses() {
        guard let url = Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "md") else { return }
        NSWorkspace.shared.open(url)
    }
    private func sectionLabel(_ title: String) -> some View { Text(title).font(.system(size: 15, weight: .medium)) }
    private func settingRow<Content: View>(_ title: String, caption: String, last: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        Group {
            if width < 820 {
                VStack(alignment: .leading, spacing: 14) {
                    settingLabel(title, caption: caption)
                    content()
                }.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .center, spacing: 20) {
                    settingLabel(title, caption: caption)
                    Spacer(minLength: 12)
                    content()
                }
            }
        }.padding(.vertical, model.settingsSection == .general ? 18 : 8)
            .overlay(alignment: .bottom) { if model.settingsSection == .general && !last { Rectangle().fill(.white.opacity(0.07)).frame(height: 1) } }
    }
    private func settingLabel(_ title: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(caption).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func openLogin() {
        onClose()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            model.loginOpen = true
        }
    }
}

struct SoleAccountPage: View {
    let page: AccountPage
    let narrow: Bool
    let open: (String) -> Void
    var body: some View {
        if page.shown {
            VStack(alignment: .leading, spacing: 22) {
                Divider().opacity(0.4)
                VStack(alignment: .leading, spacing: 12) {
                    Text(loc("Trophies")).font(.system(size: 15, weight: .medium))
                    if page.trophies != nil { summary }
                    ForEach(page.trophyTitles) { trophyTitle($0) }
                    if let note = page.trophyNote { Text(note).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text(loc("Recent games")).font(.system(size: 15, weight: .medium))
                    if let note = page.recentNote { Text(note).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 112, maximum: 150), spacing: 14, alignment: .top)], alignment: .leading, spacing: 16) {
                        ForEach(page.recent) { recent($0) }
                    }
                }
            }
        }
    }

    private var summary: some View {
        let level = VStack(alignment: .leading, spacing: 7) {
            Text(page.levelText ?? "").font(.system(size: 18, weight: .semibold))
            bar(Double(page.trophies?.summary.progress ?? 0) / 100, width: 200)
            Text(page.progressText ?? "").font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
        }
        let grades = HStack(spacing: 18) {
            ForEach(page.grades, id: \.grade) { grade in
                VStack(spacing: 4) {
                    Image(systemName: "trophy.fill").font(.system(size: 14)).foregroundStyle(colour(grade.grade))
                    Text("\(grade.count)").font(.system(size: 15, weight: .semibold)).monospacedDigit()
                    Text(grade.grade.title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }.frame(minWidth: 52)
            }
        }
        return Group {
            if narrow {
                VStack(alignment: .leading, spacing: 18) { HStack(spacing: 16) { badge; level }; grades }
            } else {
                HStack(spacing: 16) { badge; level; Spacer(minLength: 12); grades }
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Color.soleSurface, in: RoundedRectangle(cornerRadius: 16))
    }
    private var badge: some View {
        Image(systemName: "trophy.fill").font(.system(size: 22)).foregroundStyle(colour(.gold))
            .frame(width: 52, height: 52).background(.white.opacity(0.06), in: Circle())
    }
    private func trophyTitle(_ title: TrophyTitle) -> some View {
        HStack(spacing: 12) {
            SoleArtwork(url: title.iconURL, maxPixels: 160) {
                Color.white.opacity(0.06).overlay(Image(systemName: "trophy").font(.system(size: 15)).foregroundStyle(.white.opacity(0.45)))
            }.frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(title.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Text(AccountPage.trophyTitleNote(title)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) {
                Text("\(title.progress)%").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                bar(Double(title.progress) / 100, width: 80)
            }
        }
    }
    private func recent(_ recent: AccountPage.RecentGame) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            SoleGameCover(game: recent.game)
            Text(recent.game.title).font(.system(size: 13, weight: .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if let played = page.lastPlayedText(recent) { Text(played).font(.system(size: 12)).foregroundStyle(.secondary) }
        }
        .contentShape(Rectangle()).onTapGesture { open(recent.id) }
        .controllerTarget(LibraryScreen.Target.recent(recent.id)) { open(recent.id) }
        .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
    }
    private func bar(_ fraction: Double, width: CGFloat) -> some View {
        Capsule().fill(.white.opacity(0.12)).frame(width: width, height: 4)
            .overlay(alignment: .leading) { Capsule().fill(Color.soleAccent).frame(width: width * min(1, max(0, fraction)), height: 4) }
    }
    private func colour(_ grade: AccountPage.Grade) -> Color {
        let colour = grade.color
        return Color(red: colour.red, green: colour.green, blue: colour.blue)
    }
}
