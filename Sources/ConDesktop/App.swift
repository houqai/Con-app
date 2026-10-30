import CConDesktop
import CSDL2
import Foundation
import SoleCloud
import SoleCore
import SoleEngine
import SoleLogic

@MainActor final class DesktopApp {
    let model: AppModel
    let stream: StreamModel
    let device = DesktopStreamDevice()
    let page = DesktopLoginPage()
    let focus = FocusModel()
    private(set) lazy var screen: LibraryScreen = {
        let screen = LibraryScreen(model: model, focus: focus)
        screen.willChange = { [weak self] in self?.changed() }
        return screen
    }()
    var dirty = true
    private var wasConnecting = false
    private var pad: PadReading?
    private var presses = LibraryPresses()
    private var wanted: String?
    private var logged = "", loggedCourse = ""

    init() {
        stream = StreamModel(device: device, defaults: Settings.store)
        model = AppModel(store: DesktopCredentials(), website: page, player: stream, defaults: Settings.store, caches: Program.caches)
        model.willChange = { [weak self] in self?.changed() }
        stream.willChange = { [weak self] in self?.changed() }
        focus.willChange = { [weak self] in self?.changed() }
        _ = screen
        if Settings.store.string(forKey: AppLanguage.storageKey) == nil {
            let system = String((ProcessInfo.processInfo.environment["LANG"] ?? Locale.preferredLanguages.first ?? "en").prefix(2))
            if let language = AppLanguage(rawValue: system) { model.language = language.rawValue }
        }
        if Settings.store.object(forKey: Smoothness.key) == nil { Settings.store.set(Smoothness.byRefresh, forKey: Smoothness.key) }
        DispatchQueue.global(qos: .utility).async { _ = con_video_generation_available() }
        model.reloadCatalog()
        Task { await self.model.restoreAccount() }
        if let index = CommandLine.arguments.firstIndex(of: "--play"), CommandLine.arguments.count > index + 1 { wanted = CommandLine.arguments[index + 1].lowercased() }
        Task { @MainActor [weak self] in
            while let self {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self.figures()
            }
        }
    }

    private func playWanted() {
        guard let part = wanted, model.account != nil, !model.restoringAccount, !model.signingIn, !model.catalogGames.isEmpty, !model.games.isEmpty else { return }
        wanted = nil
        guard let game = model.catalogGames.first(where: { $0.title.lowercased().contains(part) }) else { logLine("play: no game has \"\(part)\" in its title"); return }
        logLine("play: \(game.title)")
        screen.play(game)
    }

    private func figures() {
        guard stream.phase.isLive, let stats = stream.stats else { return }
        let panel = StreamPanel.summary(stats)
        logLine("stream: figures size \(stats.width)x\(stats.height) decoded \(stats.shownPerSecond) lost \(stats.lostFrames) held \(stats.decodeFailures) hidden \(stats.hiddenFrames) in \(stats.hiddenRuns) runs bridged \(stats.bridgedLosses) sound \(stats.audioPlayed)/\(stats.audioReceived) loud \(stats.audioNonSilent) left out \(stats.audioErrors) · \(panel)")
    }

    private func changed() {
        dirty = true
        Task { @MainActor in
            self.report()
            if self.model.connectingCloud != self.wasConnecting { self.wasConnecting = self.model.connectingCloud; self.screen.connectingChanged(self.wasConnecting) }
            if self.screen.launching, self.stream.phase.isLive { self.screen.launching = false }
        }
    }

    private func report() {
        playWanted()
        let note = model.cloudError ?? stream.statusText ?? model.cloudStatus ?? ""
        let phase: String
        switch stream.phase { case .connecting: phase = "connecting"; case .streaming: phase = "streaming"; case .failed: phase = "failed"; default: phase = "idle" }
        let course = "stream: phase \(phase) launching \(screen.launching || model.connectingCloud) note \(note)"
        if course != loggedCourse { loggedCourse = course; if screen.launching || model.connectingCloud || phase != "idle" || !note.isEmpty { logLine(course) } }
        let line = "state: account \(model.account != nil) restoring \(model.restoringAccount) signingIn \(model.signingIn) error \(model.authError != nil)"
            + " catalogue \(model.catalogGames.count) loading \(model.loadingCatalog) catalogError \(model.catalogError != nil) history \(model.games.count) listed \(model.orderedGames.count)"
            + " phase \(stream.phase.isLive ? "live" : "idle") launching \(screen.launching)"
        guard line != logged else { return }
        logged = line
        logLine(line)
    }

    func take(_ reading: PadReading?) {
        pad = reading
        device.take(reading)
        guard let reading else { presses.reset(); return }
        for action in presses.take(reading.libraryActions, yielding: stream.hasControls, at: ProcessInfo.processInfo.systemUptime) {
            screen.gamepad(action)
        }
    }
    func tick() { if let pad { take(pad) } }

    func places(_ targets: [Target]) {
        focus.update(targets.compactMap { target in
            guard target.focusable else { return nil }
            var place = FocusTarget(id: target.id, at: (target.box.mid.x, target.box.mid.y), activate: target.action)
            place.adjust = target.adjust
            return place
        })
    }
}

struct Target {
    let id: String
    let box: Box
    var focusable = true
    var corner: Double = 12
    let action: () -> Void
    var adjust: ((Int) -> Void)? = nil
    var clip: Box? = nil
    func contains(_ x: Double, _ y: Double) -> Bool { box.contains(x, y) && (clip?.contains(x, y) ?? true) }
}
