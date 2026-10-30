import CCairo
import Foundation
import SoleCloud
import SoleCore
import SoleEngine
import SoleLogic

@MainActor final class Screens {
    let app: DesktopApp
    private var model: AppModel { app.model }
    private var screen: LibraryScreen { app.screen }
    private var stream: StreamModel { app.stream }
    private var focus: FocusModel { app.focus }

    private(set) var targets: [Target] = []
    private(set) var showsPicture = false
    private(set) var animating = false
    private(set) var blinkDue = Double.infinity
    var padName: String?
    var padHeld = ""
    var capturingControl: PadControl?
    var onFullScreen: (() -> Void)?
    var isFullScreen: () -> Bool = { false }

    private var width = 1280.0, height = 800.0
    private var hover: String?
    private var pressed: String?
    private var scrolls: [String: Double] = [:]
    private var regions: [(name: String, box: Box, content: Double)] = []
    private var searching = false
    private var registering: DiscoveredConsole?
    private var code = ""
    private var controlsUntil = 0.0
    private(set) var controlsShown = false
    private var shownFocus: String?
    private var shownChoice: Int?
    private var screenshots: [String: [String]] = [:]
    private var now = 0.0

    init(app: DesktopApp) { self.app = app }

    func draw(_ canvas: Canvas, width: Double, height: Double, now: Double) {
        self.width = width; self.height = height; self.now = now
        targets = []; regions = []; animating = false; blinkDue = .infinity
        let whole = Box(x: 0, y: 0, w: width, h: height)
        let live = stream.phase.isLive
        showsPicture = live
        if live || screen.launching {
            drawStream(canvas, whole, live: live)
        } else {
            drawBackdrop(canvas, whole)
            let covered = model.settingsOpen || model.loginOpen || !focus.choices.isEmpty
            if screen.gamePageOpen, let game = screen.game { drawPage(canvas, whole, game) }
            else {
                drawHeader(canvas)
                if model.destination == .cloud { drawLibrary(canvas, Box(x: 0, y: headerHeight, w: width, h: height - headerHeight)) }
                else { drawConsoles(canvas, Box(x: 0, y: headerHeight, w: width, h: height - headerHeight)) }
            }
            if covered || registering != nil || stream.loginPINRequest || model.message != nil { targets.removeAll() }
            if model.settingsOpen { drawSettings(canvas, whole) }
            if model.loginOpen { targets.removeAll(); drawLogin(canvas, whole) }
            if registering != nil || stream.loginPINRequest { drawCode(canvas, whole) }
            if let message = model.message { targets.removeAll(); drawMessage(canvas, whole, message) }
        }
        if !focus.choices.isEmpty { targets.removeAll(); drawChoices(canvas, whole) } else { shownChoice = nil }
        drawFocus(canvas)
    }

    private var headerHeight: Double { width < 600 ? 64 : 76 }

    private func drawBackdrop(_ canvas: Canvas, _ whole: Box) {
        let hue = screen.game?.hue ?? 100
        canvas.fill(whole, .canvas)
        canvas.glow(width * 0.8, 0, 850, Colour.hue(hue, lightness: 0.45, chroma: 0.16).with(0.75), over: whole)
        canvas.glow(width * 0.05, height * 0.9, 700, Colour.hue(hue + 40, lightness: 0.32, chroma: 0.12).with(0.5), over: whole)
        canvas.gradient(whole, from: Colour.canvas.with(0), to: Colour.canvas.with(0.9))
    }

    private var targetClip: Box?
    private func target(_ id: String, _ box: Box, corner: Double = 12, focusable: Bool = true, adjust: ((Int) -> Void)? = nil, _ action: @escaping () -> Void) {
        targets.append(Target(id: id, box: box, focusable: focusable, corner: corner, action: action, adjust: adjust, clip: targetClip))
    }
    private func hovered(_ id: String) -> Bool { hover == id }

    enum WindowAction { case fullScreen, minimize, maximize, close }
    var windowControls: (fullScreen: () -> Bool, maximized: () -> Bool, act: (WindowAction) -> Void)?

    @discardableResult
    private func drawWindowControls(_ canvas: Canvas, midY: Double, right: Double) -> Double {
        guard let controls = windowControls else { return right }
        let size = 32.0, gap = 4.0
        var x = right - size
        let full = controls.fullScreen()
        for action in full ? [WindowAction.fullScreen] : [.close, .maximize, .minimize, .fullScreen] {
            let box = Box(x: x, y: midY - size / 2, w: size, h: size)
            let id = "window-\(action)"
            if hovered(id) { canvas.fill(box, action == .close ? Colour(bytes: 232, 17, 35) : .white(0.12), radius: 8) }
            let ink = Colour.white.with(hovered(id) ? 1 : 0.75), c = box.mid
            switch action {
            case .fullScreen:
                for (dx, dy) in [(-1.0, -1.0), (1, -1), (-1, 1), (1, 1)] {
                    let corner = (x: c.x + dx * 6, y: c.y + dy * 6), inner = full ? -1.0 : 1.0
                    let tip = full ? (x: c.x + dx * 2, y: c.y + dy * 2) : corner
                    canvas.line(tip.x, tip.y, tip.x - dx * 4 * inner, tip.y, ink, width: 1.4)
                    canvas.line(tip.x, tip.y, tip.x, tip.y - dy * 4 * inner, ink, width: 1.4)
                }
            case .minimize: canvas.line(c.x - 5, c.y, c.x + 5, c.y, ink, width: 1.4)
            case .maximize:
                if controls.maximized() {
                    canvas.stroke(Box(x: c.x - 5, y: c.y - 3, w: 8, h: 8), ink, radius: 1.5, width: 1.3)
                    canvas.stroke(Box(x: c.x - 3, y: c.y - 5, w: 8, h: 8), ink.with(0.6), radius: 1.5, width: 1.3)
                } else {
                    canvas.stroke(Box(x: c.x - 5, y: c.y - 5, w: 10, h: 10), ink, radius: 2, width: 1.3)
                }
            case .close:
                canvas.line(c.x - 5, c.y - 5, c.x + 5, c.y + 5, ink, width: 1.4)
                canvas.line(c.x + 5, c.y - 5, c.x - 5, c.y + 5, ink, width: 1.4)
            }
            target(id, box, corner: 8, focusable: false) { controls.act(action) }
            x -= size + gap
        }
        return x + size
    }

    func draggable(x: Double, y: Double) -> Bool {
        let strip = stream.phase.isLive || screen.launching ? 44 : headerHeight
        guard y < strip, focus.choices.isEmpty, !model.settingsOpen, !model.loginOpen else { return false }
        return !targets.contains { $0.contains(x, y) }
    }

    @discardableResult
    private func capsuleButton(_ canvas: Canvas, _ title: String, x: Double, y: Double, prominent: Bool = false, id: String, colour: Colour? = nil, enabled: Bool = true, _ action: @escaping () -> Void) -> Box {
        let w = canvas.measure(title, size: 15, weight: .semibold).w + 48
        let box = Box(x: x, y: y, w: w, h: 42)
        let fill = prominent ? Colour.white : Colour.white(hovered(id) ? 0.18 : 0.12)
        canvas.capsule(box, enabled ? fill : fill.with(fill.a * 0.4))
        canvas.centred(title, in: box, size: 15, weight: .semibold, colour: (colour ?? (prominent ? .canvas : .white)).with(enabled ? 1 : 0.4))
        if enabled { target(id, box, corner: 21, action) }
        return box
    }

    private func iconButton(_ canvas: Canvas, _ icon: String, _ box: Box, id: String, _ action: @escaping () -> Void) {
        canvas.circle(box.mid.x, box.mid.y, box.w / 2, .white(hovered(id) ? 0.16 : 0.08))
        canvas.icon(icon, in: box.inset(box.w * 0.28), colour: .white)
        target(id, box, corner: box.w / 2, action)
    }

    private func drawHeader(_ canvas: Canvas) {
        let h = headerHeight, mid = h / 2
        var x = width < 600 ? 20.0 : 24.0
        drawLogo(canvas, Box(x: x, y: mid - 19, w: 38, h: 38))
        x += 48
        x += canvas.label("Con", x: x, midY: mid, size: 20, weight: .semibold) + (width < 1120 ? 16 : 36)
        if width >= 1120, Destination.consolesShown {
            for (title, destination) in [(loc("Cloud games"), Destination.cloud), (loc("My consoles"), .consoles)] {
                let w = canvas.measure(title, size: 16, weight: .medium).w
                let box = Box(x: x - 6, y: mid - 20, w: w + 12, h: 40)
                canvas.label(title, x: x, midY: mid, size: 16, weight: .medium, colour: .text.with(model.destination == destination ? 1 : 0.55))
                target("nav:" + title, box, corner: 8) { [model] in model.destination = destination }
                x += w + 28
            }
        }
        var right = width - (width < 600 ? 16 : 24)
        let controlsStart = drawWindowControls(canvas, midY: mid, right: right + 8)
        if controlsStart < right + 8 { right = controlsStart - 18 }
        let avatar = Box(x: right - 36, y: mid - 18, w: 36, h: 36)
        drawAvatar(canvas, avatar)
        target("account", avatar, corner: 18) { [model] in model.showSettings(.account) }
        right -= 36 + 12
        if width >= 1120 {
            iconButton(canvas, "gear", Box(x: right - 36, y: mid - 18, w: 36, h: 36), id: "icon:settings") { [model] in model.showSettings() }
            right -= 36 + 14
            if model.destination == .cloud {
                iconButton(canvas, "reload", Box(x: right - 36, y: mid - 18, w: 36, h: 36), id: "icon:reload") { [model] in model.reloadCatalog(force: true); model.reloadLibrary() }
                right -= 36 + 14
            }
        } else {
            iconButton(canvas, "menu", Box(x: right - 36, y: mid - 18, w: 36, h: 36), id: "header-menu") { [weak self] in self?.headerMenu() }
            right -= 36 + 12
        }
        if model.destination == .cloud {
            let w = width >= 1250 ? 268.0 : width >= 850 ? 200 : max(120, right - x - 8)
            drawSearch(canvas, Box(x: right - w, y: mid - 18, w: w, h: 36))
        }
    }

    private func headerMenu() {
        focus.choiceIndex = 0
        focus.choices = screen.destinationChoices + screen.appChoices()
    }

    private func drawLogo(_ canvas: Canvas, _ box: Box) {
        if let logo = Logo.surface { canvas.picture(logo, cover: box, radius: box.w * 0.22) }
        else { canvas.fill(box, Colour(0.12, 0.12, 0.12), radius: box.w * 0.2) }
    }

    private func drawAvatar(_ canvas: Canvas, _ box: Box) {
        canvas.circle(box.mid.x, box.mid.y, box.w / 2, Colour(bytes: 42, 47, 69))
        if let picture = Pictures.shared.picture(model.account?.avatarURL?.absoluteString, pixels: 192) { canvas.picture(picture, cover: box, radius: box.w / 2) }
        canvas.circle(box.mid.x, box.mid.y, box.w / 2 - 1, .white(0.18), stroke: 2)
        let dot = Box(x: box.maxX - 10, y: box.maxY - 10, w: 10, h: 10)
        canvas.circle(dot.mid.x, dot.mid.y, 6, .canvas)
        canvas.circle(dot.mid.x, dot.mid.y, 4, model.account == nil ? Colour(0.55, 0.55, 0.55) : Colour(bytes: 52, 199, 89))
    }

    private func drawSearch(_ canvas: Canvas, _ box: Box) {
        canvas.capsule(box, .white(searching ? 0.14 : 0.08))
        canvas.stroke(box, .white(searching ? 0.4 : 0.08), radius: box.h / 2, width: 1)
        canvas.icon("search", in: Box(x: box.x + 14, y: box.mid.y - 8, w: 16, h: 16), colour: .white(0.6))
        let text = model.search.isEmpty && !searching ? loc("Search games") : model.search + (searching && Int(now * 2) % 2 == 0 ? "|" : "")
        canvas.label(text, x: box.x + 39, midY: box.mid.y, size: 14, colour: .text.with(model.search.isEmpty && !searching ? 0.45 : 1), maxWidth: box.w - 52)
        if searching { blinkDue = ((now * 2).rounded(.down) + 1) / 2 }
        target(LibraryScreen.Target.search, box, corner: box.h / 2) { [weak self] in self?.startSearching() }
    }

    private func startSearching() { searching = true; SDLKeyboard.start(); app.dirty = true }
    private func stopSearching() { searching = false; SDLKeyboard.stop(); app.dirty = true }

    private var columns: Int { max(2, min(6, Int((width - 48 + 22) / 202))) }

    private func drawLibrary(_ canvas: Canvas, _ area: Box) {
        if screen.columns != columns { screen.columns = columns }
        let narrow = width < 1050
        var y = area.y + 12
        var x = 24.0
        x += canvas.label(loc("Cloud catalog"), x: x, midY: y + 16, size: width < 760 ? 14 : 18, weight: .semibold) + 12
        if width >= 760 { x += canvas.label(loc("%@ games", model.filteredGames.count), x: x, midY: y + 16, size: 14, colour: .text.with(0.5)) + 20 }
        for backend in [CloudBackend.ps5, .psPlusPC, .ps3] {
            let name = backend.console
            let size = width < 760 ? 12.0 : 14
            let w = canvas.measure(name, size: size, weight: .semibold).w + (width < 760 ? 20 : 32)
            let box = Box(x: x, y: y + 16 - 15, w: w, h: 30)
            let chosen = model.catalogBackend == backend
            canvas.capsule(box, chosen ? .white : .white(hovered("catalog-source:" + backend.rawValue) ? 0.12 : 0.07))
            canvas.centred(name, in: box, size: size, weight: .semibold, colour: chosen ? .canvas : .white(0.7))
            target("catalog-source:" + backend.rawValue, box, corner: 15) { [weak self] in
                guard let self, self.model.catalogBackend != backend else { return }
                self.model.catalogBackend = backend; self.screen.catalogReplaced(); self.scrolls["library"] = 0
            }
            x += w + 8
        }
        let filters = model.availableLibraryFilters
        let widths = filters.map { canvas.measure(loc($0.rawValue), size: 13).w + 32 }
        let capsuleWidth = widths.reduce(8, +)
        var fx = narrow ? 24 : width - 24 - capsuleWidth
        let fy = narrow ? y + 46 : y + 1
        canvas.capsule(Box(x: fx, y: fy, w: capsuleWidth, h: 38), .white(0.07))
        fx += 4
        for (index, filter) in filters.enumerated() {
            let box = Box(x: fx, y: fy + 4, w: widths[index], h: 30)
            let chosen = model.filter == filter
            if chosen { canvas.capsule(box, .white) }
            canvas.centred(loc(filter.rawValue), in: box, size: 13, colour: chosen ? .canvas : .white(0.75))
            target(LibraryScreen.Target.filter(filter), box, corner: 15) { [weak self] in
                guard let self, self.model.filter != filter else { return }
                self.model.filter = filter; self.screen.startOver(); self.scrolls["library"] = 0
            }
            fx += widths[index]
        }
        y = fy + 46
        let view = Box(x: 0, y: y, w: width, h: area.maxY - y)
        let games = screen.games, shown = min(games.count, screen.visibleCount)
        let tile = (width - 48 - Double(columns - 1) * 22) / Double(columns)
        let rows = (shown + columns - 1) / columns
        var content = 20 + Double(rows) * (tile + 22)
        let offset = scrolls["library"] ?? 0
        canvas.save(); canvas.clip(view); targetClip = view
        for index in 0..<shown {
            let game = games[index]
            let box = Box(x: 24 + Double(index % columns) * (tile + 22), y: view.y + 20 + Double(index / columns) * (tile + 22) - offset, w: tile, h: tile)
            guard box.maxY > view.y - 40, box.y < view.maxY + 40 else {
                target(LibraryScreen.Target.game(game.id), box, corner: 18) { [weak self] in self?.open(game) }
                continue
            }
            drawCard(canvas, game, box)
        }
        var bottom = view.y + content - offset
        if let empty = model.filteredGames.isEmpty ? screen.emptyText : nil {
            canvas.text(empty, x: 40, y: bottom + 20, size: 15, colour: .white(0.6), width: width - 80, lines: 3, centred: true)
            content += 80; bottom += 80
        }
        if screen.hasMore {
            let w = canvas.measure(loc("Show more"), size: 15, weight: .semibold).w + 48
            capsuleButton(canvas, loc("Show more"), x: width / 2 - w / 2, y: bottom + 2, id: LibraryScreen.Target.more) { [weak self] in self?.screen.showMore() }
            content += 70; bottom += 70
        }
        if let error = model.catalogError ?? model.pcCatalogError ?? model.libraryError {
            canvas.text(error, x: 24, y: bottom + 6, size: 13, colour: .white(0.6), width: width - 48, lines: 3)
            content += 60
        }
        canvas.restore(); targetClip = nil
        regions.append(("library", view, content + 40))
    }

    private func open(_ game: Game) { stopSearching(); model.openGame(game); screen.gamePageChanged(open: true); scrolls["page"] = 0 }

    private func drawCard(_ canvas: Canvas, _ game: Game, _ box: Box) {
        let id = LibraryScreen.Target.game(game.id)
        let selected = focus.isFocused(id)
        let grown = selected ? box.inset(-box.w * 0.03) : box
        canvas.shadow(grown, radius: 12, blur: selected ? 24 : 8, dy: selected ? 8 : 3, opacity: selected ? 0.45 : 0.2)
        drawCover(canvas, game, grown, radius: 12, icon: 32)
        canvas.save(); canvas.clip(grown, radius: 12)
        let shade = Box(x: grown.x, y: grown.maxY - 74, w: grown.w, h: 74)
        canvas.gradient(shade, from: .black(0), to: .black(0.85))
        let title = canvas.measure(game.title, size: 15, weight: .semibold, width: grown.w - 24, lines: 2)
        canvas.text(game.title, x: grown.x + 12, y: grown.maxY - 12 - title.h, size: 15, weight: .semibold, colour: .white, width: grown.w - 24, lines: 2)
        canvas.restore()
        if selected {
            canvas.ring(grown, radius: 12, outset: 3, width: 3, .canvas)
            canvas.ring(grown, radius: 12, outset: 6, width: 3, .white)
        }
        let star = Box(x: grown.maxX - 36, y: grown.y + 8, w: 28, h: 28)
        canvas.circle(star.mid.x, star.mid.y, 14, .black(0.35))
        canvas.icon(game.favorite ? "star.fill" : "star", in: star.inset(7), colour: .white)
        target(id, box, corner: 18) { [weak self] in self?.open(game) }
        target("star:" + game.id, star, corner: 14, focusable: false) { [model] in model.toggleFavorite(game.id) }
    }

    private func drawCover(_ canvas: Canvas, _ game: Game, _ box: Box, radius: Double, icon: Double) {
        canvas.fill(box, .hue(game.hue), radius: radius)
        if let picture = Pictures.shared.picture(game.artworkURL?.absoluteString, pixels: 640) {
            canvas.picture(picture, cover: box, radius: radius)
        } else {
            canvas.icon("gamecontroller", in: Box(x: box.mid.x - icon * 0.65, y: box.mid.y - icon * 0.65, w: icon * 1.3, h: icon * 1.3), colour: .white(0.6), weight: 1.8)
        }
    }

    private func drawPage(_ canvas: Canvas, _ whole: Box, _ game: Game) {
        canvas.fill(whole, .hue(game.hue, lightness: 0.4, chroma: 0.12))
        if let tiny = Pictures.shared.picture(game.artworkURL?.absoluteString, pixels: 12) { canvas.picture(tiny, cover: whole) }
        canvas.fill(whole, Colour.canvas.with(0.45))
        canvas.gradient(whole, from: Colour.canvas.with(0.2), to: Colour.canvas.with(0.9))
        let narrow = width < 900, compact = width < 1100
        let side = narrow ? 24.0 : 64
        let offset = scrolls["page"] ?? 0
        let view = Box(x: 0, y: 0, w: width, h: height)
        canvas.save(); canvas.clip(view); targetClip = view
        let thumbnails = max(100, min(220, height * 0.26))
        let hero = max(120, height - 96 - 60 - 24 - thumbnails - 54)
        let size = min(min(narrow ? 160 : 320, hero), width * 0.24)
        let shots = loadScreenshots(of: game)
        let available = width - 2 * side
        let count = min(max(1, shots.count), available > 1000 ? 6 : available > 700 ? 4 : 3)
        let rows = (shots.count + count - 1) / count
        let shotWidth = min((available - Double(count - 1) * 16) / Double(count), max(40, (thumbnails - Double(max(1, rows) - 1) * 16) / Double(max(1, rows))) * 16 / 9)
        let top = narrow ? 76.0 : 96, content = size + (shots.isEmpty ? 0 : 24 + 34 + Double(rows) * (shotWidth * 9 / 16 + 16) - 16)
        var y = top + max(0, (height - top - 60 - content) / 2) - offset
        drawCover(canvas, game, Box(x: side, y: y, w: size, h: size), radius: 12, icon: 40)
        let left = side + size + (narrow ? 24 : 44), room = width - left - side
        let kicker = ([game.platform] + game.genres.prefix(1).map(Game.genreName)).joined(separator: " · ").uppercased()
        let titleSize = narrow ? 28.0 : 44
        let titleHeight = canvas.measure(game.title, size: titleSize, weight: .bold, width: room, lines: 2).h
        let block = 16 + 12 + titleHeight + 26 + 48
        var dy = y + max(0, (size - block) / 2)
        canvas.text(kicker, x: left, y: dy, size: 13, weight: .semibold, colour: .text.with(0.7), width: room)
        dy += 28
        canvas.text(game.title, x: left, y: dy, size: titleSize, weight: .bold, colour: .text, width: room, lines: 2)
        dy += titleHeight + 26
        var bx = left
        let play = Box(x: bx, y: dy, w: canvas.measure(loc("Play"), size: 16, weight: .semibold).w + 92, h: 48)
        canvas.capsule(play, hovered(LibraryScreen.Target.pagePlay) ? Colour(0.9, 0.92, 0.96) : .white)
        canvas.icon("play", in: Box(x: play.x + 34, y: play.mid.y - 7, w: 14, h: 14), colour: .canvas)
        canvas.label(loc("Play"), x: play.x + 58, midY: play.mid.y, size: 16, weight: .semibold, colour: .canvas)
        target(LibraryScreen.Target.pagePlay, play, corner: 24) { [weak self] in self?.screen.play(game) }
        bx += play.w + 12
        func pill(_ icon: String, _ title: String?, id: String, _ action: @escaping () -> Void) {
            let w = (title.map { canvas.measure($0, size: 15, weight: .medium).w + 24 } ?? 0) + 56
            let box = Box(x: bx, y: dy, w: w, h: 48)
            canvas.capsule(box, .white(hovered(id) ? 0.18 : 0.12))
            canvas.icon(icon, in: Box(x: box.x + 20, y: box.mid.y - 8, w: 16, h: 16), colour: .white)
            if let title { canvas.label(title, x: box.x + 44, midY: box.mid.y, size: 15, weight: .medium, colour: .white) }
            target(id, box, corner: 24, action)
            bx += w + 12
        }
        pill(game.favorite ? "star.fill" : "star", compact ? nil : (game.favorite ? loc("In favorites") : loc("Add to favorites")), id: "page-favorite") { [model] in model.toggleFavorite(game.id) }
        if let store = game.storeURL {
            pill("arrow.up.right", compact ? nil : loc("PS Store"), id: "page-store") { Self.openInBrowser(store) }
        }
        y += size + 24
        if !shots.isEmpty {
            canvas.text(loc("Screenshots"), x: side, y: y, size: 18, weight: .semibold)
            y += 34
            let w = shotWidth
            for (index, address) in shots.enumerated() {
                let box = Box(x: side + Double(index % count) * (w + 16), y: y + Double(index / count) * (w * 9 / 16 + 16), w: w, h: w * 9 / 16)
                canvas.fill(box, .white(0.05), radius: 10)
                if let picture = Pictures.shared.picture(address, pixels: 640) { canvas.picture(picture, cover: box, radius: 10) }
                target("screenshot:\(index)", box, corner: 14) {}
            }
            y += Double(rows) * (w * 9 / 16 + 16)
        }
        canvas.restore(); targetClip = nil
        regions.append(("page", view, y + offset + 60))
        let back = Box(x: 24, y: narrow ? 14 : 20, w: canvas.measure(loc("Catalog"), size: 14, weight: .medium).w + 50, h: 36)
        canvas.capsule(back, .white(hovered("page-back") ? 0.16 : 0.1))
        canvas.icon("chevron.left", in: Box(x: back.x + 12, y: back.mid.y - 8, w: 16, h: 16), colour: .white)
        canvas.label(loc("Catalog"), x: back.x + 34, midY: back.mid.y, size: 14, weight: .medium, colour: .white)
        target("page-back", back, corner: 18) { [weak self] in self?.model.gameOpen = false; self?.screen.gamePageChanged(open: false) }
    }

    private func loadScreenshots(of game: Game) -> [String] {
        if let known = screenshots[game.id] { return known }
        screenshots[game.id] = []
        let model = self.model
        Task { @MainActor [weak self] in
            let urls = await model.screenshots(for: game)
            self?.screenshots[game.id] = urls.map(\.absoluteString)
            self?.app.dirty = true
        }
        return []
    }

    static func openInBrowser(_ url: URL) { Program.open(url.absoluteString) }

    private func drawConsoles(_ canvas: Canvas, _ area: Box) {
        let offset = scrolls["consoles"] ?? 0
        canvas.save(); canvas.clip(area); targetClip = area
        var y = area.y + (width < 850 ? 32 : 80) - offset
        let side = 24.0, room = min(760, width - 48)
        y += canvas.text(loc("Your PlayStation. Right here."), x: side, y: y, size: width < 850 ? 36 : 52, weight: .bold, width: room, lines: 2).h + 12
        y += canvas.text(loc("Connect to your console and pick up where you left off."), x: side, y: y, size: 18, colour: .text.with(0.7), width: room, lines: 2).h + 42
        func banner(_ text: String, tint: Colour, button: String? = nil, _ action: (() -> Void)? = nil) {
            let h = max(48, canvas.measure(text, size: 15, width: room - 180, lines: 4).h + 26)
            let box = Box(x: side, y: y, w: room, h: h)
            canvas.fill(box, tint.with(0.1), radius: 9)
            canvas.text(text, x: side + 13, y: y + 13, size: 15, colour: .white(0.6), width: room - (button == nil ? 26 : 180), lines: 4)
            if let button, let action { capsuleButton(canvas, button, x: box.maxX - 13 - canvas.measure(button, size: 15, weight: .semibold).w - 48, y: box.mid.y - 21, id: "banner:" + button, action) }
            y += h + 14
        }
        if model.account == nil { banner(loc("Sign in to PlayStation to register consoles and start Remote Play."), tint: .accent, button: loc("Connect PlayStation")) { [model] in model.loginOpen = true } }
        if let status = stream.statusText { banner(status, tint: .accent) }
        if case .failed(let reason) = stream.phase { banner(reason, tint: Colour(1, 0.62, 0.04), button: "×") { [stream] in stream.clearFailure() } }
        canvas.icon("waves", in: Box(x: side, y: y, w: 18, h: 18), colour: .accent)
        canvas.label(loc("On the local network"), x: side + 26, midY: y + 9, size: 16, weight: .semibold)
        y += 32
        if stream.consoles.isEmpty {
            y += canvas.text(loc("Looking for PlayStation consoles on the network. Make sure your PS5 or PS4 is on, is on the same network, and has Remote Play enabled in its settings."),
                             x: side, y: y, size: 15, colour: .white(0.55), width: room, lines: 4).h + 14
        }
        let busy = stream.phase.isBusy, signedIn = model.account != nil
        for console in stream.consoles {
            let box = Box(x: side, y: y, w: room, h: 72)
            canvas.fill(box, .white(0.05), radius: 10)
            canvas.icon("gamecontroller", in: Box(x: side + 15, y: box.mid.y - 14, w: 28, h: 28), colour: .accent)
            canvas.label(console.name.isEmpty ? console.address : console.name, x: side + 57, midY: box.mid.y - 9, size: 14, weight: .medium, maxWidth: room - 260)
            let (state, colour): (String, Colour) = console.state == .ready ? (loc("Ready"), Colour(bytes: 52, 199, 89)) : console.state == .standby ? (loc("Rest mode"), Colour(bytes: 255, 214, 10)) : (loc("Unknown"), Colour(0.55, 0.55, 0.55))
            let platform = canvas.label(console.isPS5 ? "PS5" : "PS4", x: side + 57, midY: box.mid.y + 11, size: 10, weight: .semibold, colour: .white(0.55))
            canvas.label(state, x: side + 63 + platform, midY: box.mid.y + 11, size: 10, weight: .medium, colour: colour)
            if stream.isRegistered(console.id) {
                capsuleButton(canvas, loc("Play"), x: box.maxX - 15 - canvas.measure(loc("Play"), size: 15, weight: .semibold).w - 48, y: box.mid.y - 21, prominent: true, id: "console-play:" + console.id, enabled: !busy && signedIn) { [stream] in
                    Task { await stream.connect(console: console) }
                }
            } else {
                capsuleButton(canvas, loc("Connect"), x: box.maxX - 15 - canvas.measure(loc("Connect"), size: 15, weight: .semibold).w - 48, y: box.mid.y - 21, id: "console-register:" + console.id, enabled: !busy && signedIn) { [weak self] in
                    self?.registering = console; self?.code = ""; SDLKeyboard.start()
                }
            }
            y += 86
        }
        if !stream.offlineRegistered.isEmpty {
            y += canvas.text(loc("Saved"), x: side, y: y + 10, size: 16, weight: .semibold).h + 24
            for entry in stream.offlineRegistered {
                let box = Box(x: side, y: y, w: room, h: 64)
                canvas.fill(box, .white(0.035), radius: 10)
                canvas.label(entry.name, x: side + 57, midY: box.mid.y - 8, size: 14, weight: .medium, colour: .text.with(0.7))
                canvas.label(loc("Offline"), x: side + 57, midY: box.mid.y + 11, size: 10, colour: .white(0.4))
                capsuleButton(canvas, loc("Remove"), x: box.maxX - 15 - canvas.measure(loc("Remove"), size: 15, weight: .semibold).w - 48, y: box.mid.y - 21, id: "console-remove:" + entry.hostID, colour: .danger) { [stream] in
                    stream.removeRegistration(hostID: entry.hostID)
                }
                y += 78
            }
        }
        y += canvas.text(loc("Remote Play connects directly to your console on the local network. It is separate from cloud streaming."),
                         x: side, y: y + 10, size: 13, colour: .white(0.4), width: room, lines: 3).h + 40
        canvas.restore(); targetClip = nil
        regions.append(("consoles", area, y + offset - area.y))
    }

    private func drawSettings(_ canvas: Canvas, _ whole: Box) {
        canvas.fill(whole, .scrim)
        target("settings-outside", whole, focusable: false) { [model] in model.settingsOpen = false }
        let w = min(1000, width - (width < 600 ? 24 : 40)), h = min(640, height - 40)
        let panel = Box(x: (width - w) / 2, y: (height - h) / 2, w: w, h: h)
        target("settings-panel", panel, focusable: false) {}
        canvas.fill(panel, .panel, radius: 22)
        canvas.stroke(panel, .white(0.08), radius: 22)
        let narrow = w < 820
        var main = panel
        if narrow {
            var x = panel.x + 20, y = panel.y + 16
            for section in SettingsSection.allCases {
                let title = loc(section.rawValue), tw = canvas.measure(title, size: 14, weight: .medium).w + 28
                if x + tw > panel.maxX - 20 { x = panel.x + 20; y += 46 }
                let box = Box(x: x, y: y, w: tw, h: 38)
                let chosen = model.settingsSection == section
                canvas.capsule(box, chosen ? .white : .white(0.07))
                canvas.centred(title, in: box, size: 14, weight: .medium, colour: chosen ? .canvas : .white)
                target(LibraryScreen.Target.settingsTab(section), box, corner: 19) { [model] in model.settingsSection = section }
                x += tw + 8
            }
            main = Box(x: panel.x, y: y + 50, w: panel.w, h: panel.maxY - y - 50)
        } else {
            let side = Box(x: panel.x, y: panel.y, w: 220, h: panel.h)
            canvas.save(); canvas.clip(panel, radius: 22); canvas.fill(side, .white(0.025)); canvas.restore()
            canvas.text(loc("Settings"), x: side.x + 30, y: side.y + 30, size: 20, weight: .semibold)
            var y = side.y + 74
            for section in SettingsSection.allCases {
                let box = Box(x: side.x + 18, y: y, w: 184, h: 44)
                let chosen = model.settingsSection == section
                if chosen { canvas.fill(box, .white, radius: 12) } else if hovered(LibraryScreen.Target.settingsTab(section)) { canvas.fill(box, .white(0.06), radius: 12) }
                canvas.label(loc(section.rawValue), x: box.x + 14, midY: box.mid.y, size: 15, weight: chosen ? .medium : .regular, colour: chosen ? Colour(0.10, 0.12, 0.18) : .text)
                target(LibraryScreen.Target.settingsTab(section), box) { [model] in model.settingsSection = section }
                y += 49
            }
            canvas.text("Con · \(ConVersion.number)", x: side.x + 28, y: side.maxY - 48, size: 13, colour: .white(0.55))
            main = Box(x: side.maxX, y: panel.y + 30, w: panel.w - 220, h: panel.h - 30)
        }
        let inner = width < 760 ? 20.0 : 40
        canvas.label(loc(model.settingsSection.rawValue), x: main.x + inner, midY: main.y + 18, size: 24, weight: .semibold)
        iconButton(canvas, "xmark", Box(x: main.maxX - inner - 36, y: main.y, w: 36, h: 36), id: "icon:close-settings") { [model] in model.settingsOpen = false }
        let view = Box(x: main.x, y: main.y + 56, w: main.w, h: main.maxY - main.y - 72)
        let offset = scrolls["settings:" + model.settingsSection.id] ?? 0
        canvas.save(); canvas.clip(view); targetClip = view
        var rows = SettingsRows(screens: self, canvas: canvas, x: main.x + inner, y: view.y - offset, width: main.w - 2 * inner, narrow: narrow)
        switch model.settingsSection {
        case .general: generalSettings(&rows)
        case .account: accountSettings(&rows)
        case .stream: streamSettings(&rows)
        case .controller: controllerSettings(&rows)
        case .about: aboutSettings(&rows)
        }
        canvas.restore(); targetClip = nil
        regions.append(("settings:" + model.settingsSection.id, view, rows.y + offset - view.y + 20))
    }

    struct SettingsRows {
        let screens: Screens
        let canvas: Canvas
        let x: Double
        var y: Double
        let width: Double
        let narrow: Bool

        mutating func row(_ title: String, _ caption: String, control: (w: Double, h: Double), lined: Bool = true, draw: (Box) -> Void) {
            let labelWidth = narrow ? width : width - control.w - 24
            let titleHeight = canvas.measure(title, size: 15, weight: .semibold, width: labelWidth).h
            let captionHeight = canvas.measure(caption, size: 13, width: labelWidth, lines: 3).h
            let labelHeight = titleHeight + 5 + captionHeight
            let rowHeight = narrow ? labelHeight + 14 + control.h : max(labelHeight, control.h)
            let top = y + 16
            canvas.text(title, x: x, y: narrow ? top : top + (rowHeight - labelHeight) / 2, size: 15, weight: .semibold, width: labelWidth)
            canvas.text(caption, x: x, y: (narrow ? top : top + (rowHeight - labelHeight) / 2) + titleHeight + 5, size: 13, colour: .white(0.55), width: labelWidth, lines: 3)
            let box = narrow ? Box(x: x, y: top + labelHeight + 14, w: control.w, h: control.h) : Box(x: x + width - control.w, y: top + (rowHeight - control.h) / 2, w: control.w, h: control.h)
            draw(box)
            y = top + rowHeight + 16
            if lined { canvas.fill(Box(x: x, y: y - 0.5, w: width, h: 1), .white(0.07)) }
        }
        mutating func text(_ words: String, size: Double = 13, colour: Colour = .white(0.55)) {
            y += canvas.text(words, x: x, y: y + 6, size: size, colour: colour, width: width, lines: 6).h + 14
        }
    }

    private func select(_ canvas: Canvas, _ box: Box, id: String, title: String, enabled: Bool = true, values: [(String, String)], chosen: String, apply: @escaping (String) -> Void) {
        canvas.fill(box, .white(enabled ? (hovered("select:" + id) ? 0.14 : 0.1) : 0.05), radius: 10)
        canvas.label(title, x: box.x + 12, midY: box.mid.y, size: 14, colour: .white.with(enabled ? 1 : 0.4), maxWidth: box.w - 40)
        canvas.icon("chevron.down", in: Box(x: box.maxX - 24, y: box.mid.y - 6, w: 12, h: 12), colour: .white(0.65), weight: 2.6)
        guard enabled else { return }
        target("select:" + id, box, corner: 10) { [focus] in
            focus.choiceIndex = values.firstIndex { $0.0 == chosen } ?? 0
            focus.choices = values.map { pair in FocusModel.Choice(title: pair.1, action: { apply(pair.0) }) }
        }
    }

    private func toggle(_ canvas: Canvas, _ box: Box, on: Bool, id: String, _ action: @escaping () -> Void) {
        canvas.capsule(box, on ? .accent : .white(0.18))
        canvas.circle(on ? box.maxX - 14 : box.x + 14, box.mid.y, 11, .white)
        target("toggle:" + id, box, corner: 14, action)
    }

    private func generalSettings(_ rows: inout SettingsRows) {
        let model = self.model, canvas = rows.canvas
        let languages = AppLanguage.allCases.map { ($0.rawValue, $0.name) }
        rows.row(loc("App language"), loc("The language of Con's interface"), control: (200, 36)) { box in
            select(canvas, box, id: "app-language", title: AppLanguage(rawValue: model.language)?.name ?? model.language, values: languages, chosen: model.language) { model.language = $0 }
        }
        let locales = CatalogRegion.choices
        rows.row(loc("Catalog region"), loc("Sony's list of games · not the datacenter choice"), control: (200, 36)) { box in
            select(canvas, box, id: "catalog-locale", title: locales.first { $0.0 == model.catalogLocale }?.1 ?? model.catalogLocale, values: locales, chosen: model.catalogLocale) { model.catalogLocale = $0; model.reloadCatalog() }
        }
        let fits = [("fit", loc("Fit")), (AppModel.fill, loc("Fill"))]
        rows.row(loc("Picture size"), loc("How the video fills the window"), control: (200, 36), lined: false) { box in
            select(canvas, box, id: "video-fit", title: fits.first { $0.0 == model.videoFit }?.1 ?? model.videoFit, values: fits, chosen: model.videoFit) { model.videoFit = $0 }
        }
    }

    private func accountSettings(_ rows: inout SettingsRows) {
        let canvas = rows.canvas, model = self.model
        let card = Box(x: rows.x, y: rows.y + 10, w: rows.width, h: 108)
        canvas.fill(card, .white(0.05), radius: 16)
        drawAvatar(canvas, Box(x: card.x + 22, y: card.mid.y - 32, w: 64, h: 64))
        canvas.text(model.account?.displayName ?? loc("Your PlayStation account"), x: card.x + 101, y: card.mid.y - 26, size: 20, weight: .semibold, width: card.w - 120)
        let note = model.restoringAccount ? loc("Restoring your saved sign-in…") : model.account == nil ? loc("Sign in to open your game library.") : loc("Account connected")
        canvas.text(note, x: card.x + 101, y: card.mid.y + 6, size: 14, colour: .white(0.55), width: card.w - 120)
        rows.y = card.maxY + 22
        var x = rows.x
        if model.account != nil {
            x = capsuleButton(canvas, loc("Refresh sign-in"), x: x, y: rows.y, prominent: true, id: "account-refresh") { model.settingsOpen = false; model.loginOpen = true }.maxX + 12
        }
        let title = model.restoringAccount ? loc("Restoring sign-in…") : model.account == nil ? loc("Connect account") : loc("Sign out")
        capsuleButton(canvas, title, x: x, y: rows.y, prominent: model.account == nil, id: "account-login", colour: model.account == nil ? nil : .danger, enabled: !model.restoringAccount && !model.signingOut) {
            if model.account != nil { model.signOut() } else { model.settingsOpen = false; model.loginOpen = true }
        }
        rows.y += 42 + 16
        if model.account == nil, !model.restoringAccount, let error = model.authError { rows.text(error, size: 15, colour: .accent) }
        rows.text(loc("You sign in on the PlayStation page. Con never asks for your password in forms of its own."), size: 14)
        accountPage(&rows)
    }

    private func accountPage(_ rows: inout SettingsRows) {
        let page = AccountPage(model)
        guard page.shown else { return }
        let canvas = rows.canvas
        func colour(_ grade: AccountPage.Grade) -> Colour { let c = grade.color; return Colour(c.red, c.green, c.blue) }
        func bar(_ box: Box, _ fraction: Double) {
            canvas.capsule(box, .white(0.12))
            canvas.capsule(Box(x: box.x, y: box.y, w: max(box.h, box.w * min(1, max(0, fraction))), h: box.h), .accent)
        }
        canvas.fill(Box(x: rows.x, y: rows.y + 6, w: rows.width, h: 1), .white(0.12))
        rows.y += 28
        rows.y += canvas.text(loc("Trophies"), x: rows.x, y: rows.y, size: 15, weight: .medium).h + 12
        if let trophies = page.trophies {
            let narrow = rows.width < 560
            let card = Box(x: rows.x, y: rows.y, w: rows.width, h: narrow ? 172 : 96)
            canvas.fill(card, .white(0.05), radius: 16)
            let badge = Box(x: card.x + 18, y: card.y + 22, w: 52, h: 52)
            canvas.circle(badge.mid.x, badge.mid.y, 26, .white(0.06))
            canvas.icon("trophy", in: badge.inset(14), colour: colour(.gold), weight: 1.8)
            let lx = badge.maxX + 16
            canvas.label(page.levelText ?? "", x: lx, midY: card.y + 30, size: 18, weight: .semibold)
            bar(Box(x: lx, y: card.y + 46, w: min(200, card.maxX - lx - 18), h: 4), Double(trophies.summary.progress) / 100)
            canvas.label(page.progressText ?? "", x: lx, midY: card.y + 64, size: 12, colour: .white(0.55))
            let across = 64.0
            var gx = narrow ? card.x + 10 : card.maxX - 14 - across * 4
            let gy = narrow ? card.y + 96 : card.y + 14
            for (grade, count) in page.grades {
                canvas.icon("trophy", in: Box(x: gx + across / 2 - 8, y: gy + 4, w: 16, h: 16), colour: colour(grade), weight: 1.8)
                canvas.centred("\(count)", in: Box(x: gx, y: gy + 24, w: across, h: 20), size: 15, weight: .semibold)
                canvas.centred(grade.title, in: Box(x: gx, y: gy + 46, w: across, h: 16), size: 11, colour: .white(0.55))
                gx += across
            }
            rows.y = card.maxY + 12
        }
        for title in page.trophyTitles {
            let icon = Box(x: rows.x, y: rows.y + 4, w: 44, h: 44)
            if let picture = Pictures.shared.picture(title.iconURL?.absoluteString, pixels: 160) { canvas.picture(picture, cover: icon, radius: 9) }
            else { canvas.fill(icon, .white(0.06), radius: 9); canvas.icon("trophy", in: icon.inset(13), colour: .white(0.45), weight: 1.6) }
            let right = rows.x + rows.width, textX = icon.maxX + 12, room = right - 104 - textX
            canvas.label(title.name, x: textX, midY: icon.y + 13, size: 14, weight: .medium, maxWidth: room)
            canvas.label(AccountPage.trophyTitleNote(title), x: textX, midY: icon.y + 32, size: 12, colour: .white(0.55), maxWidth: room)
            let percent = "\(title.progress)%", pw = canvas.measure(percent, size: 13, weight: .semibold).w
            canvas.label(percent, x: right - pw, midY: icon.y + 13, size: 13, weight: .semibold)
            bar(Box(x: right - 80, y: icon.y + 30, w: 80, h: 4), Double(title.progress) / 100)
            rows.y = icon.maxY + 8
        }
        if let note = page.trophyNote { rows.text(note) }
        rows.y += 14
        rows.y += canvas.text(loc("Recent games"), x: rows.x, y: rows.y, size: 15, weight: .medium).h + 12
        if let note = page.recentNote { rows.text(note) }
        let gap = 14.0, across = max(2, Int((rows.width + gap) / (112 + gap)))
        let tile = min(150, (rows.width - gap * Double(across - 1)) / Double(across))
        let titleHeight = canvas.measure("Ag\nAg", size: 13, weight: .semibold, width: tile, lines: 2).h
        let height = tile + 7 + titleHeight + 22
        for (index, recent) in page.recent.enumerated() {
            let box = Box(x: rows.x + Double(index % across) * (tile + gap), y: rows.y + Double(index / across) * (height + 16), w: tile, h: height)
            drawCover(canvas, recent.game, Box(x: box.x, y: box.y, w: tile, h: tile), radius: 12, icon: 24)
            let id = LibraryScreen.Target.recent(recent.id)
            if hovered(id) { canvas.stroke(Box(x: box.x, y: box.y, w: tile, h: tile), .white(0.25), radius: 12, width: 1.5) }
            canvas.text(recent.game.title, x: box.x, y: box.y + tile + 7, size: 13, weight: .semibold, width: tile, lines: 2)
            if let played = page.lastPlayedText(recent) { canvas.label(played, x: box.x, midY: box.maxY - 8, size: 12, colour: .white(0.55), maxWidth: tile) }
            target(id, box, corner: 12) { [weak self] in self?.screen.openRecent(recent.id); self?.scrolls["page"] = 0 }
        }
        if !page.recent.isEmpty { rows.y += Double((page.recent.count + across - 1) / across) * (height + 16) }
    }

    private func streamSettings(_ rows: inout SettingsRows) {
        let canvas = rows.canvas, model = self.model
        canvas.text(loc("Video quality"), x: rows.x, y: rows.y + 14, size: 15, weight: .medium)
        rows.y += 44
        let presets = StreamQuality.heights.map { ($0, StreamQuality.note(height: $0)) }
        let across = rows.width < 650 ? 2 : rows.width < 900 ? 3 : 6
        let tile = (rows.width - Double(across - 1) * 10) / Double(across)
        for (index, preset) in presets.enumerated() {
            let box = Box(x: rows.x + Double(index % across) * (tile + 10), y: rows.y + Double(index / across) * 82, w: tile, h: 72)
            let chosen = model.resolution == preset.0
            canvas.fill(box, .white(chosen ? 0.1 : 0.05), radius: 14)
            canvas.stroke(box, chosen ? .white : .white(0.08), radius: 14, width: 2)
            canvas.centred(StreamQuality.name(height: preset.0), in: Box(x: box.x, y: box.y + 12, w: box.w, h: 26), size: 17, weight: .bold)
            canvas.centred(preset.1, in: Box(x: box.x, y: box.y + 38, w: box.w, h: 20), size: 12, colour: .white(0.55))
            target("quality:\(preset.0)", box, corner: 14) { model.selectPreset(preset.0) }
        }
        rows.y += Double((presets.count + across - 1) / across) * 82
        rows.row(loc("Bitrate"), loc("Higher means more detail and more data used"), control: (rows.narrow ? rows.width : 260, 44)) { box in
            canvas.label(loc("%@ Mbps", Int(model.bitrate)), x: box.x, midY: box.y + 8, size: 13, colour: .white(0.55))
            let track = Box(x: box.x, y: box.y + 28, w: box.w, h: 4)
            let fraction = (model.bitrate - StreamQuality.lowestBitrate) / (StreamQuality.highestBitrate - StreamQuality.lowestBitrate)
            canvas.capsule(track, .white(0.15))
            canvas.capsule(Box(x: track.x, y: track.y, w: track.w * fraction, h: 4), .accent)
            canvas.circle(track.x + track.w * fraction, track.mid.y, 9, .white)
            target("bitrate", Box(x: box.x - 8, y: box.y + 14, w: box.w + 16, h: 30), corner: 8, adjust: { step in model.bitrate = StreamQuality.clampedBitrate(model.bitrate + Double(step)) }) {}
            Slider.tracks["bitrate"] = (track.x, track.w, { value in model.bitrate = (StreamQuality.lowestBitrate + (StreamQuality.highestBitrate - StreamQuality.lowestBitrate) * value).rounded() })
        }
        let smoothness = Smoothness.choices(byRefresh: true).map { (String($0.0), $0.1) }
        let lead = String(Smoothness.read(Settings.store))
        rows.row(loc("Smooth presentation"), loc("How long a frame waits for an even rhythm. Less is sooner on screen, but less even on an uneven network"), control: (min(260, rows.width), 36)) { box in
            select(canvas, box, id: "smoothness", title: smoothness.first { $0.0 == lead }?.1 ?? lead, values: smoothness, chosen: lead) { [weak self] in
                Settings.store.set(Int($0) ?? Smoothness.byRefresh, forKey: Smoothness.key); self?.app.dirty = true
            }
        }
        let stream = self.stream
        if app.device.upscalingSupported {
            rows.row(loc("Upscaler"), loc("Enlarges the picture to the size of the window while keeping it sharp, when the stream is smaller than the screen. Puts a little load on the graphics card"), control: (48, 28)) { box in
                toggle(canvas, box, on: stream.upscaling, id: "upscaling") { stream.upscaling.toggle() }
            }
            if stream.upscaling, app.device.upscaleMethods.count > 1 {
                let ways = app.device.upscaleMethods.map { ($0.rawValue, $0.title) }, way = stream.upscaleMethod.used(in: app.device.upscaleMethods).rawValue
                rows.row(loc("Upscaling method"), loc("FSR 1 and NIS — sharp edges with almost no delay; Anime4K — a neural network that adds detail"), control: (min(200, rows.width), 36)) { box in
                    select(canvas, box, id: "upscale-method", title: ways.first { $0.0 == way }?.1 ?? way, values: ways, chosen: way) { [stream] in
                        stream.upscaleMethod = Upscale.Method(rawValue: $0) ?? .fsr
                    }
                }
            }
            if stream.upscaling {
                let amounts = Upscale.Amount.allCases.map { ($0.rawValue, $0.title) }, amount = stream.upscaleAmount.rawValue
                rows.row(loc("Enlargement"), loc("By how much to enlarge the stream. More is sharper but slower"), control: (min(200, rows.width), 36)) { box in
                    select(canvas, box, id: "upscale-amount", title: amounts.first { $0.0 == amount }?.1 ?? amount, values: amounts, chosen: amount) { [stream] in
                        stream.upscaleAmount = Upscale.Amount(rawValue: $0) ?? .double
                    }
                }
            }
        }
        if stream.frameGenerationSupported {
            rows.row(loc("Frame generation"), loc("A frame between two frames of the game when the display can show it. Adds delay"), control: (48, 28)) { box in
                toggle(canvas, box, on: stream.frameGeneration, id: "generation") { stream.frameGeneration.toggle() }
            }
        } else {
            rows.row(loc("Frame generation"), loc("Frame generation is not available on this computer"), control: (48, 28)) { box in
                canvas.capsule(box, .white(0.08))
                canvas.circle(box.x + 14, box.mid.y, 11, .white(0.3))
            }
        }
        rows.row(loc("Trophy notifications"), loc("Show trophies earned over the game"), control: (48, 28)) { box in
            toggle(canvas, box, on: model.trophyNotices, id: "trophy-notices") { model.trophyNotices.toggle() }
        }
        rows.row(loc("Distant servers"), loc("Reports a lower latency to Sony so that a server further than 80 ms is accepted. This breaks Sony's rules: at your own risk"), control: (48, 28)) { box in
            toggle(canvas, box, on: model.distantServers, id: "distant-servers") { model.distantServers.toggle() }
        }
        let datacenters = model.datacenters
        let values = model.datacenterChoices
        rows.row(loc("Datacenter"), model.datacenterCaption, control: (min(260, rows.width), 36), lined: false) { box in
            select(canvas, box, id: "datacenter", title: values.first { $0.0 == model.selectedDatacenter }?.1 ?? model.selectedDatacenter, enabled: !datacenters.isEmpty, values: values, chosen: model.selectedDatacenter) { model.selectedDatacenter = $0 }
        }
        rows.text(model.datacenterNote)
        if model.cloudCanRetry, model.account != nil {
            let w = canvas.text(loc("Connect again"), x: rows.x, y: rows.y, size: 12, colour: .accent).w
            target("retry", Box(x: rows.x, y: rows.y - 4, w: w, h: 24), corner: 6) { model.settingsOpen = false; model.connectCloud() }
            rows.y += 30
        }
        canvas.fill(Box(x: rows.x, y: rows.y, w: rows.width, h: 1), .white(0.12))
        let games = GameLanguage.all.map { ($0.code, $0.name) }
        rows.row(loc("Game language"), loc("If the game supports it"), control: (200, 36), lined: false) { box in
            select(canvas, box, id: "game-language", title: games.first { $0.0 == model.gameLanguage }?.1 ?? model.gameLanguage, values: games, chosen: model.gameLanguage) { model.gameLanguage = $0 }
        }
    }

    private func controllerSettings(_ rows: inout SettingsRows) {
        let canvas = rows.canvas, model = self.model
        rows.y += 10
        if let name = padName {
            let card = Box(x: rows.x, y: rows.y, w: rows.width, h: 96)
            canvas.fill(card, .white(0.05), radius: 16)
            canvas.icon("gamecontroller", in: Box(x: card.x + 22, y: card.y + 20, w: 22, h: 22), colour: .accent)
            canvas.label(name, x: card.x + 52, midY: card.y + 31, size: 16, weight: .semibold, maxWidth: card.w - 74)
            canvas.label(padHeld, x: card.x + 22, midY: card.y + 66, size: 14, colour: .accent, maxWidth: card.w - 44)
            rows.y = card.maxY + 14
        } else {
            canvas.icon("gamecontroller", in: Box(x: rows.x, y: rows.y, w: 20, h: 20), colour: .text)
            canvas.label(loc("No controller connected"), x: rows.x + 28, midY: rows.y + 10, size: 15, weight: .medium)
            rows.y += 30
            rows.text(loc("Connect a DualSense, DualShock or another compatible gamepad over USB or Bluetooth. Con finds it on its own. Without a gamepad you can play with the keyboard."), size: 14)
        }
        rows.text(loc("The input check works locally. During a stream the game is controlled by the first connected controller and the keyboard, together or separately."), colour: .white(0.4))
        rows.row(loc("Vibration"), loc("Feedback in games that support it"), control: (48, 28), lined: false) { box in
            toggle(canvas, box, on: model.haptics, id: "haptics") { model.haptics.toggle() }
        }
        rows.y += 10
        keyboardCard(&rows)
        rows.y += 14
        mouseCard(&rows)
    }

    private func cardHead(_ canvas: Canvas, _ card: Box, icon: String, title: String, caption: String, side: Double) -> Double {
        let x = card.x + 22, room = card.w - 44 - (side > 0 ? side + 12 : 0)
        canvas.icon(icon, in: Box(x: x, y: card.y + 20, w: 20, h: 20), colour: .white)
        canvas.label(title, x: x + 28, midY: card.y + 30, size: 16, weight: .semibold, maxWidth: room - 28)
        let words = canvas.text(caption, x: x, y: card.y + 47, size: 13, colour: .white(0.55), width: room, lines: 4)
        return card.y + 47 + words.h + 18
    }

    private func keyboardCard(_ rows: inout SettingsRows) {
        let canvas = rows.canvas
        let layout = KeyboardLayout.stored(in: Settings.store)
        let x = rows.x + 22, inner = rows.width - 44
        let top = rows.y
        canvas.fill(Box(x: rows.x, y: top, w: rows.width, h: keyboardCardHeight), .white(0.05), radius: 16)
        let reset = loc("Reset"), resetWidth = canvas.measure(reset, size: 13).w
        var y = cardHead(canvas, Box(x: rows.x, y: top, w: rows.width, h: 0), icon: "keyboard", title: loc("Keyboard"),
                         caption: loc("Works during a stream, with a controller or without one. Click a key in the list, then press the new one."), side: resetWidth)
        let standard = layout == .standard
        canvas.label(reset, x: x + inner - resetWidth, midY: top + 30, size: 13, colour: Colour.accent.with(standard ? 0.4 : 1))
        if !standard {
            target("keys-reset", Box(x: x + inner - resetWidth - 6, y: top + 18, w: resetWidth + 12, h: 24), corner: 6) { [weak self] in
                self?.capturingControl = nil
                KeyboardLayout.standard.store(in: Settings.store)
            }
        }
        let across = max(1, Int((inner + 8) / (190 + 8)))
        let tile = (inner - Double(across - 1) * 8) / Double(across)
        for group in PadControl.groups {
            y += canvas.text(group.title, x: x, y: y, size: 12, weight: .medium, colour: .white(0.55), width: inner).h + 8
            for (index, control) in group.controls.enumerated() {
                let box = Box(x: x + Double(index % across) * (tile + 8), y: y + Double(index / across) * 46, w: tile, h: 38)
                let id = "key:" + control.rawValue, waiting = capturingControl == control
                canvas.fill(box, .white(hovered(id) ? 0.07 : 0.04), radius: 10)
                let name = waiting ? loc("press a key") : layout.keys[control].map(Key.name) ?? "—"
                let badgeWidth = min(box.w * 0.6, max(34, canvas.measure(name, size: 13, weight: .semibold).w + 18))
                let badge = Box(x: box.maxX - 6 - badgeWidth, y: box.mid.y - 13, w: badgeWidth, h: 26)
                canvas.label(control.title, x: box.x + 12, midY: box.mid.y, size: 14, colour: .white(0.85), maxWidth: badge.x - box.x - 18)
                canvas.fill(badge, waiting ? .accent : .white(0.12), radius: 7)
                canvas.centred(name, in: badge, size: 13, weight: .semibold, colour: waiting ? .canvas : .white)
                target(id, box, corner: 10) { [weak self] in
                    guard let self else { return }
                    self.capturingControl = waiting ? nil : control
                }
            }
            y += Double((group.controls.count + across - 1) / across) * 46 + 10
        }
        let height = y + 10 - top
        if height != keyboardCardHeight { keyboardCardHeight = height; app.dirty = true }
        rows.y = top + height
    }
    private var keyboardCardHeight = 0.0

    private func mouseCard(_ rows: inout SettingsRows) {
        let canvas = rows.canvas, store = Settings.store
        let settings = MouseSettings(defaults: store)
        let x = rows.x + 22, inner = rows.width - 44, top = rows.y
        canvas.fill(Box(x: rows.x, y: top, w: rows.width, h: mouseCardHeight), .white(0.05), radius: 16)
        let caption = loc("Click the picture during a stream: the pointer disappears and the mouse turns the camera. The %@ key brings the pointer back.", DesktopStreamDevice.systemKeyName)
        var y = cardHead(canvas, Box(x: rows.x, y: top, w: rows.width, h: 0), icon: "computermouse", title: loc("Mouse"), caption: caption, side: 48)
        toggle(canvas, Box(x: x + inner - 48, y: top + 18, w: 48, h: 28), on: settings.enabled, id: "mouse-camera") {
            store.set(!settings.enabled, forKey: MouseSettings.enabledKey)
        }
        if settings.enabled {
            let label = loc("Sensitivity"), labelWidth = canvas.measure(label, size: 14).w
            let trackWidth = max(80, min(220, inner - labelWidth - 50))
            canvas.label(label, x: x, midY: y + 15, size: 14, colour: .white(0.85))
            let range = MouseSettings.sensitivities, value = Double(settings.sensitivity)
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let track = Box(x: x + inner - 32 - trackWidth, y: y + 13, w: trackWidth, h: 4)
            canvas.capsule(track, .white(0.15))
            canvas.capsule(Box(x: track.x, y: track.y, w: track.w * fraction, h: 4), .accent)
            canvas.circle(track.x + track.w * fraction, track.mid.y, 9, .white)
            let number = "\(Int(value))", numberWidth = canvas.measure(number, size: 13, weight: .semibold).w
            canvas.label(number, x: x + inner - numberWidth, midY: y + 15, size: 13, weight: .semibold)
            func set(_ value: Double) { store.set(min(range.upperBound, max(range.lowerBound, value.rounded())), forKey: MouseSettings.sensitivityKey) }
            target("mouse-sensitivity", Box(x: track.x - 8, y: y, w: track.w + 16, h: 30), corner: 8, adjust: { step in set(value + Double(step)) }) {}
            Slider.tracks["mouse-sensitivity"] = (track.x, track.w, { fraction in set(range.lowerBound + (range.upperBound - range.lowerBound) * fraction) })
            y += 30 + 14
            let choices = MouseSettings.buttonChoices.map { ($0.value, $0.title) }
            let chosen = settings.bumpers ? "bumpers" : "triggers"
            let selectWidth = min(250, inner - 130)
            canvas.label(loc("Mouse buttons"), x: x, midY: y + 18, size: 14, colour: .white(0.85), maxWidth: inner - selectWidth - 12)
            select(canvas, Box(x: x + inner - selectWidth, y: y, w: selectWidth, h: 36), id: "mouse-buttons", title: choices.first { $0.0 == chosen }?.1 ?? chosen,
                   values: choices, chosen: chosen) { store.set($0, forKey: MouseSettings.buttonsKey) }
            y += 36 + 6
        }
        let height = y + 14 - top
        if height != mouseCardHeight { mouseCardHeight = height; app.dirty = true }
        rows.y = top + height
    }
    private var mouseCardHeight = 0.0

    private func aboutSettings(_ rows: inout SettingsRows) {
        let canvas = rows.canvas
        drawLogo(canvas, Box(x: rows.x, y: rows.y + 10, w: 84, h: 84))
        rows.y += 110
        rows.y += canvas.text("Con", x: rows.x, y: rows.y, size: 40, weight: .semibold).h + 6
        rows.y += canvas.text(loc("Your games. Your computer."), x: rows.x, y: rows.y, size: 18, colour: .white(0.55)).h + 10
        rows.y += canvas.text(loc("Version %@", ConVersion.number), x: rows.x, y: rows.y, size: 13, colour: .white(0.4)).h + 16
        canvas.fill(Box(x: rows.x, y: rows.y, w: rows.width, h: 1), .white(0.12))
        rows.y += 16
        rows.y += canvas.text(loc("Cloud games and connection to your PlayStation."), x: rows.x, y: rows.y, size: 14, colour: .white(0.55)).h + 16
        let w = canvas.text(loc("Licenses"), x: rows.x, y: rows.y, size: 14, colour: .accent).w
        target("about-licenses", Box(x: rows.x, y: rows.y - 4, w: w, h: 26), corner: 6) {
            if let notices = Program.resource("THIRD-PARTY-NOTICES.md") { Self.openInBrowser(notices) }
        }
        rows.y += 30
    }

    private func drawLogin(_ canvas: Canvas, _ whole: Box) {
        canvas.fill(whole, .scrim)
        let model = self.model
        target("login-outside", whole, focusable: false) { model.cancelSignIn(); model.loginOpen = false }
        let w = min(460, width - 32), h = 395.0
        let sheet = Box(x: (width - w) / 2, y: (height - h) / 2, w: w, h: h)
        target("login-sheet", sheet, focusable: false) {}
        canvas.fill(sheet, .canvas, radius: 22)
        canvas.stroke(sheet, .white(0.08), radius: 22)
        drawLogo(canvas, Box(x: sheet.x + 23, y: sheet.y + 18, w: 25, h: 25))
        canvas.label("Con", x: sheet.x + 55, midY: sheet.y + 30.5, size: 14, weight: .medium)
        iconButton(canvas, "xmark", Box(x: sheet.maxX - 23 - 36, y: sheet.y + 12, w: 36, h: 36), id: "icon:close-login") { model.cancelSignIn(); model.loginOpen = false }
        var y = sheet.y + 66
        canvas.icon("person", in: Box(x: sheet.mid.x - 23, y: y, w: 46, h: 46), colour: .accent)
        y += 66
        canvas.centred(loc("Connect PlayStation"), in: Box(x: sheet.x, y: y, w: w, h: 30), size: 24, weight: .semibold)
        y += 38
        canvas.centred(loc("One sign-in for the library and the cloud."), in: Box(x: sheet.x, y: y, w: w, h: 16), size: 12, colour: .white(0.55))
        y += 32
        canvas.text(loc("Sign in on Sony's website.\nSony offers the sign-in methods, including QR."), x: sheet.x + 30, y: y, size: 12, colour: .white(0.55), width: w - 60, lines: 3, centred: true)
        y += 50
        let go = Box(x: sheet.mid.x - 133, y: y, w: 266, h: 42)
        let enabled = !model.signingIn && !model.restoringAccount && !model.signingOut
        canvas.capsule(go, Colour.white.with(enabled ? 1 : 0.4))
        canvas.centred((model.signingIn ? loc("Waiting for sign-in…") : loc("Sign in on Sony's website")) + "  ↗", in: go, size: 15, weight: .semibold, colour: .canvas)
        if enabled { target("login-go", go, corner: 21) { model.signIn() } }
        y += 54
        if model.signingIn {
            let cancel = Box(x: sheet.mid.x - 60, y: y - 6, w: 120, h: 24)
            canvas.centred(loc("Cancel sign-in"), in: cancel, size: 11, colour: .white(0.55))
            target("login-cancel", cancel, corner: 8) { model.cancelSignIn() }
        }
        y += 22
        canvas.text(model.authError ?? loc("Your password is entered only on Sony's website."), x: sheet.x + 30, y: y, size: 10, colour: model.authError == nil ? .white(0.55) : .accent, width: w - 60, lines: 3, centred: true)
    }

    private func drawChoices(_ canvas: Canvas, _ whole: Box) {
        canvas.fill(whole, .black(0.55))
        target("choices-outside", whole, focusable: false) { [focus] in focus.choices = [] }
        let w = min(360, width - 32), rowHeight = 46.0
        let h = min(min(360, height - 120), Double(focus.choices.count) * (rowHeight + 6) + 26)
        let box = Box(x: (width - w) / 2, y: (height - h) / 2, w: w, h: h)
        target("choices", box, focusable: false) {}
        canvas.fill(box, .panel, radius: 18)
        let content = Double(focus.choices.count) * (rowHeight + 6) + 26, most = max(0, content - h)
        if shownChoice != focus.choiceIndex {
            shownChoice = focus.choiceIndex
            scrolls["choices"] = max(0, min(Double(focus.choiceIndex) * (rowHeight + 6) - h / 2 + rowHeight, most))
        }
        let offset = min(scrolls["choices"] ?? 0, most)
        regions.append(("choices", box, content))
        canvas.save(); canvas.clip(box, radius: 18)
        for (index, choice) in focus.choices.enumerated() {
            let row = Box(x: box.x + 16, y: box.y + 16 + Double(index) * (rowHeight + 6) - offset, w: w - 32, h: rowHeight)
            let chosen = index == focus.choiceIndex
            if chosen { canvas.fill(row, Colour.accent.with(0.3), radius: 10); canvas.stroke(row, .white, radius: 10, width: 2) }
            else if hovered("choice:\(index)") { canvas.fill(row, .white(0.06), radius: 10) }
            canvas.label(choice.title, x: row.x + 14, midY: row.mid.y, size: 16, maxWidth: row.w - 28)
            target("choice:\(index)", row, corner: 10, focusable: false) { [focus] in let action = choice.action; focus.choices = []; action() }
        }
        canvas.restore()
    }

    private func drawMessage(_ canvas: Canvas, _ whole: Box, _ message: String) {
        canvas.fill(whole, .scrim)
        let w = min(400, width - 40)
        let textHeight = canvas.measure(message, size: 14, width: w - 44, lines: 8).h
        let box = Box(x: (width - w) / 2, y: (height - textHeight - 120) / 2, w: w, h: textHeight + 120)
        canvas.fill(box, .panel, radius: 18)
        canvas.text("Con", x: box.x + 22, y: box.y + 22, size: 17, weight: .semibold)
        canvas.text(message, x: box.x + 22, y: box.y + 52, size: 14, colour: .white(0.75), width: w - 44, lines: 8)
        let ok = loc("OK"), okWidth = canvas.measure(ok, size: 15, weight: .semibold).w + 48
        capsuleButton(canvas, ok, x: box.maxX - 22 - okWidth, y: box.maxY - 60, prominent: true, id: "message-ok") { [model] in model.message = nil }
    }

    private func drawCode(_ canvas: Canvas, _ whole: Box) {
        canvas.fill(whole, .scrim)
        let w = min(380, width - 32), pinRequest = registering == nil
        let title = pinRequest ? loc("Console login code") : loc("Register %@", registering.map { $0.name.isEmpty ? $0.address : $0.name } ?? "")
        let note = pinRequest ? loc("The console asked for the account login code. Enter it to continue.") : loc("On the console, open Settings → System → Remote Play → Link Device and enter the 8-digit code shown.")
        let noteHeight = canvas.measure(note, size: 15, width: w - 44, lines: 5).h
        let box = Box(x: (width - w) / 2, y: 80, w: w, h: noteHeight + 200)
        canvas.fill(box, .panel, radius: 18)
        canvas.text(title, x: box.x + 22, y: box.y + 22, size: 15, weight: .semibold, width: w - 44)
        canvas.text(note, x: box.x + 22, y: box.y + 50, size: 15, colour: .white(0.6), width: w - 44, lines: 5)
        let field = Box(x: box.x + 22, y: box.y + 66 + noteHeight, w: w - 44, h: 44)
        canvas.fill(field, .white(0.1), radius: 10)
        let needed = pinRequest ? 4 : 8
        canvas.label(code.isEmpty ? (pinRequest ? loc("Code") : loc("8-digit code")) : code + (Int(now * 2) % 2 == 0 ? "|" : ""), x: field.x + 12, midY: field.mid.y, size: 18, colour: .text.with(code.isEmpty ? 0.4 : 1))
        if !code.isEmpty { blinkDue = ((now * 2).rounded(.down) + 1) / 2 }
        let done = pinRequest ? loc("Confirm") : loc("Register"), doneWidth = canvas.measure(done, size: 15, weight: .semibold).w + 48
        capsuleButton(canvas, done, x: box.maxX - 22 - doneWidth, y: box.maxY - 62, prominent: true, id: "code-done", enabled: code.count == needed) { [weak self] in self?.finishCode() }
        if !pinRequest {
            let cancel = loc("Cancel"), cancelWidth = canvas.measure(cancel, size: 15, weight: .semibold).w + 48
            capsuleButton(canvas, cancel, x: box.maxX - 34 - doneWidth - cancelWidth, y: box.maxY - 62, id: "code-cancel") { [weak self] in self?.registering = nil; SDLKeyboard.stop() }
        }
    }

    private func finishCode() {
        let entered = code
        if let console = registering { Task { await stream.register(console: console, pin: entered) } }
        else { stream.submitLoginPIN(entered) }
        registering = nil; code = ""; SDLKeyboard.stop(); app.dirty = true
    }

    private func drawStream(_ canvas: Canvas, _ whole: Box, live: Bool) {
        if !live {
            drawLaunch(canvas, whole)
            return
        }
        let phaseConnecting: Bool = { if case .connecting = stream.phase { return true } else { return false } }()
        if phaseConnecting {
            canvas.fill(whole, .black)
            let spin = now.truncatingRemainder(dividingBy: 1)
            canvas.save()
            canvas.set(.white); cairo_set_line_width(canvas.cairo, 4); cairo_set_line_cap(canvas.cairo, CAIRO_LINE_CAP_ROUND)
            cairo_new_sub_path(canvas.cairo)
            cairo_arc(canvas.cairo, width / 2, height / 2 - 16, 18, spin * 2 * .pi, spin * 2 * .pi + 4.5)
            cairo_stroke(canvas.cairo)
            canvas.restore()
            canvas.centred(stream.statusText ?? loc("Connecting…"), in: Box(x: 0, y: height / 2 + 14, w: width, h: 20), size: 13, colour: .white(0.85))
            animating = true
        }
        let controlsShown = now < controlsUntil || phaseConnecting
        self.controlsShown = controlsShown
        var x = 12.0
        if controlsShown {
            let leave = loc("Disconnect")
            let leaveWidth = canvas.measure(leave, size: 12, weight: .semibold).w + 30
            let bar = Box(x: x, y: 12, w: 3 + leaveWidth + 11 + 4 * 26 - 2 + 3, h: 30)
            canvas.fill(bar, .black(0.42), radius: 9); canvas.stroke(bar, .white(0.08), radius: 9)
            let leaveBox = Box(x: bar.x + 3, y: bar.y + 3, w: leaveWidth, h: 24)
            if hovered("stream-leave") { canvas.fill(leaveBox, .red, radius: 6) }
            canvas.icon("xmark", in: Box(x: leaveBox.x + 8, y: leaveBox.mid.y - 4.5, w: 9, h: 9), colour: .white, weight: 2.6)
            canvas.label(leave, x: leaveBox.x + 22, midY: leaveBox.mid.y, size: 12, weight: .semibold, colour: .white)
            target("stream-leave", leaveBox, corner: 6) { [model, stream] in model.cancelCloud(); stream.disconnect() }
            canvas.fill(Box(x: leaveBox.maxX + 5, y: bar.mid.y - 7, w: 1, h: 14), .white(0.14))
            var bx = leaveBox.maxX + 11
            func round(_ icon: String, on: Bool, id: String, enabled: Bool = true, _ action: @escaping () -> Void) {
                let box = Box(x: bx, y: bar.y + 3, w: 24, h: 24)
                if on { canvas.fill(box, .white(0.2), radius: 6) } else if hovered(id) && enabled { canvas.fill(box, .white(0.1), radius: 6) }
                canvas.icon(icon, in: box.inset(5.5), colour: .white(!enabled ? 0.26 : on || hovered(id) ? 1 : 0.75))
                if enabled { target(id, box, corner: 6, action) }
                bx += 26
            }
            round("chart", on: stream.statsVisible, id: "stream-stats") { [stream] in stream.statsVisible.toggle() }
            round("generation", on: stream.frameGeneration, id: "stream-generation", enabled: stream.frameGenerationSupported) { [stream] in stream.frameGeneration.toggle() }
            round("fullscreen", on: isFullScreen(), id: "stream-full") { [weak self] in self?.onFullScreen?() }
            round("menu", on: false, id: "stream-menu") { [stream] in stream.openMenu() }
            x = bar.maxX + 8
            drawWindowControls(canvas, midY: 27, right: width - 8)
        }
        if stream.statsVisible, let stats = stream.stats { drawStats(canvas, stats, x: x, midY: 27, room: width - x - 12) }
        if let notice = stream.trophyNotice { drawTrophy(canvas, notice) }
        if stream.menu.isOpen { drawMenu(canvas, whole) }
    }

    private func drawTrophy(_ canvas: Canvas, _ notice: TrophyNotice) {
        let w = min(340, width - 24), box = Box(x: width - w - 16, y: 52, w: w, h: 72)
        let grade = AccountPage.Grade(notice.grade).color, colour = Colour(grade.red, grade.green, grade.blue)
        canvas.shadow(box, radius: 18, blur: 16, dy: 6, opacity: 0.4)
        canvas.fill(box, .black(0.62), radius: 18)
        canvas.stroke(box, .white(0.08), radius: 18)
        let art = Box(x: box.x + 12, y: box.y + 12, w: 48, h: 48)
        canvas.fill(art, .white(0.06), radius: 8)
        if let picture = Pictures.shared.picture(notice.iconURL?.absoluteString, pixels: 160) { canvas.picture(picture, cover: art, radius: 8) }
        else { canvas.icon("trophy", in: art.inset(13), colour: colour) }
        let textX = art.maxX + 12, room = box.maxX - 12 - textX
        canvas.icon("trophy", in: Box(x: textX, y: box.y + 16, w: 11, h: 11), colour: colour)
        canvas.label(notice.heading, x: textX + 16, midY: box.y + 21.5, size: 11, weight: .semibold, colour: colour, maxWidth: room - 16)
        canvas.text(notice.title, x: textX, y: box.y + 31, size: 14, weight: .semibold, colour: .white, width: room, lines: 2)
    }

    private func drawLaunch(_ canvas: Canvas, _ whole: Box) {
        let game = model.cloudLaunchingGame ?? screen.game
        canvas.fill(whole, .canvas)
        if let game { canvas.fill(whole, .hue(game.hue, lightness: 0.4, chroma: 0.12)); if let tiny = Pictures.shared.picture(game.artworkURL?.absoluteString, pixels: 12) { canvas.picture(tiny, cover: whole) } }
        canvas.fill(whole, Colour.canvas.with(0.82))
        let size = max(96, min(220, min(width / 2, height - 300)))
        var y = (height - size - 34 - 34 - 40 - 22 - 34 - 42) / 2
        if let game {
            drawCover(canvas, game, Box(x: width / 2 - size / 2, y: y, w: size, h: size), radius: 12, icon: 40)
            y += size + 34
            canvas.centred(game.title, in: Box(x: 0, y: y, w: width, h: 34), size: 28, weight: .semibold)
            y += 46
        }
        let status = model.cloudError ?? model.cloudStatus ?? loc("Checking access to the game…")
        let statusHeight = canvas.text(status, x: max(24, width / 2 - 320), y: y, size: 15, colour: .text.with(0.7), width: min(640, width - 48), lines: 4, centred: true).h
        y += statusHeight + 22
        if model.connectingCloud {
            let track = Box(x: width / 2 - 160, y: y, w: 320, h: 4)
            canvas.capsule(track, .white(0.15))
            let run = now.truncatingRemainder(dividingBy: 1.4) / 1.4
            canvas.save(); canvas.clip(track, radius: 2)
            canvas.capsule(Box(x: track.x - 100 + (track.w + 100) * run, y: track.y, w: 100, h: 4), .white)
            canvas.restore()
            animating = true
        }
        y += 34
        let title = model.connectingCloud ? loc("Cancel") : loc("Close"), w = canvas.measure(title, size: 15, weight: .semibold).w + 48
        capsuleButton(canvas, title, x: width / 2 - w / 2, y: y, id: LibraryScreen.Target.launchCancel) { [screen, stream] in screen.cancelLaunch(); stream.disconnect() }
    }

    private func drawStats(_ canvas: Canvas, _ stats: StreamStats, x: Double, midY: Double, room: Double) {
        func line(_ detail: StreamPanel.Detail) -> (cells: [StreamPanel.Cell], width: Double) {
            let cells = StreamPanel.cells(stats, detail: detail)
            var w = 22.0
            for (index, cell) in cells.enumerated() {
                if index > 0 { w += 12 }
                w += 11 + 4 + canvas.measure(cell.value, size: 12, weight: .semibold).w
                if let unit = cell.unit { w += 4 + canvas.measure(unit, size: 12).w }
            }
            return (cells, w)
        }
        let chosen = [StreamPanel.Detail.full, .less, .least].map(line).first { $0.width <= room } ?? line(.least)
        let bar = Box(x: x, y: midY - 15, w: chosen.width, h: 30)
        canvas.fill(bar, .black(0.42), radius: 9); canvas.stroke(bar, .white(0.08), radius: 9)
        var cx = bar.x + 11
        for (index, cell) in chosen.cells.enumerated() {
            if index > 0 { cx += 12 }
            let trouble = cell.trouble.color
            let tint = cell.kind == .ping ? Colour(trouble.red, trouble.green, trouble.blue) : .white(0.5)
            canvas.icon(cell.kind.icon, in: Box(x: cx, y: bar.mid.y - 5.5, w: 11, h: 11), colour: tint, weight: 2.2)
            cx += 15
            cx += canvas.label(cell.value, x: cx, midY: bar.mid.y, size: 12, weight: .semibold, colour: .white)
            if let unit = cell.unit { cx += 4 + canvas.label(unit, x: cx + 4, midY: bar.mid.y, size: 12, colour: .white(0.5)) }
        }
    }

    private func drawMenu(_ canvas: Canvas, _ whole: Box) {
        canvas.fill(whole, .black(0.55))
        target("menu-outside", whole, focusable: false) { [stream] in stream.closeMenu() }
        let menu = stream.menu, game = stream.streamGame
        let w = min(420, width - 48)
        let delay: String? = stream.stats.flatMap { stats in
            guard let delay = stats.delayMs, let ping = stats.livePingMs ?? stats.measuredPingMs else { return nil }
            return loc("Delay ≈ %@ ms: network %@ + computer %@", delay, ping, delay - ping)
        }
        let header = delay == nil ? 108.0 : 130, rows = Double(menu.items.count) * 42 + 14
        let notice = stream.silentSound ? 44.0 : 0
        let box = Box(x: (width - w) / 2, y: max(16, (height - header - notice - rows - 40) / 2), w: w, h: header + notice + rows)
        target("menu-panel", box, focusable: false) {}
        canvas.fill(box, .black(0.62), radius: 18)
        canvas.stroke(box, .white(0.08), radius: 18)
        let art = Box(x: box.x + 18, y: box.y + 18, w: 72, h: 72)
        canvas.fill(art, .white(0.06), radius: 12)
        if let picture = Pictures.shared.picture(game?.artwork?.absoluteString, pixels: 320) { canvas.picture(picture, cover: art, radius: 12) }
        else { canvas.icon("gamecontroller", in: art.inset(24), colour: .white(0.35)) }
        canvas.stroke(art, .white(0.08), radius: 12)
        let textX = art.maxX + 14, room = box.maxX - 18 - textX
        var y = art.y
        y += canvas.text(game?.title ?? StreamGame.unknownTitle, x: textX, y: y, size: 17, weight: .semibold, colour: .white, width: room, lines: 2).h + 6
        var fx = textX
        if let platform = game?.platform {
            let badge = Box(x: fx, y: y, w: canvas.measure(platform, size: 10, weight: .bold).w + 12, h: 16)
            canvas.fill(badge, .white, radius: 4); canvas.centred(platform, in: badge, size: 10, weight: .bold, colour: .canvas)
            fx = badge.maxX + 8
        }
        canvas.label((stream.stats?.facts ?? []).joined(separator: " · "), x: fx, midY: y + 8, size: 12, colour: .white(0.65), maxWidth: box.maxX - 18 - fx)
        y += 22
        if let stats = stream.stats { canvas.label(loc("Playing for %@ min", max(1, stats.seconds / 60)), x: textX, midY: y + 8, size: 12, colour: .white(0.65)) }
        if let delay { y += 22; canvas.label(delay, x: textX, midY: y + 8, size: 12, colour: .white(0.65), maxWidth: room) }
        canvas.fill(Box(x: box.x, y: box.y + header, w: box.w, h: 1), .white(0.08))
        if notice > 0 {
            canvas.label(loc("The server sent the game without sound"), x: box.x + 18, midY: box.y + header + notice / 2, size: 13, weight: .medium, colour: Colour(1, 0.78, 0.4), maxWidth: box.w - 36)
            canvas.fill(Box(x: box.x, y: box.y + header + notice, w: box.w, h: 1), .white(0.08))
        }
        for (index, item) in menu.items.enumerated() {
            let row = Box(x: box.x + 8, y: box.y + header + notice + 8 + Double(index) * 42, w: box.w - 16, h: 40)
            let chosen = index == menu.selection, leaving = item == .leave
            if chosen { canvas.fill(row, .white(0.1), radius: 9); canvas.stroke(row, .white(0.9), radius: 9, width: 2) }
            let iconBox = Box(x: row.x + 10, y: row.mid.y - 12, w: 24, h: 24)
            canvas.fill(iconBox, (leaving ? Colour(1, 0, 0) : .white).with(0.12), radius: 6)
            let icons: [StreamMenu.Item: String] = [.restart: "reload", .resume: "play", .stats: "chart", .generation: "generation", .upscaler: "magnifier", .upscaleAmount: "magnifier.plus",
                                                    .upscaleMethod: "magnifier", .fullScreen: "fullscreen", .leave: "xmark"]
            let icon = icons[item] ?? "menu"
            canvas.icon(icon, in: iconBox.inset(6), colour: leaving ? Colour(1, 0.42, 0.4) : .white)
            canvas.label(item.title(fullScreen: isFullScreen()), x: row.x + 45, midY: row.mid.y, size: 13, weight: .medium, colour: leaving ? Colour(1, 0.5, 0.48) : .white)
            if let on = item.isOn(statsVisible: stream.statsVisible, generation: stream.frameGeneration, upscaling: stream.upscaling) {
                let state = StreamMenu.Item.stateText(on), sw = canvas.measure(state, size: 12).w
                canvas.label(state, x: row.maxX - 10 - sw, midY: row.mid.y, size: 12, colour: on ? .accent : .white(0.45))
            } else if let value = item.value(upscaleAmount: stream.upscaleAmount, upscaleMethod: stream.upscaleMethod) {
                let vw = canvas.measure(value, size: 12).w
                canvas.label(value, x: row.maxX - 10 - vw, midY: row.mid.y, size: 12, colour: .accent)
            }
            target("menu:\(index)", row, corner: 9, focusable: false) { [stream] in stream.choose(item) }
        }
        if Pad.connected {
            var hx = width / 2 - 120
            for (key, title) in [("✕", loc("Select")), ("○", loc("Back")), ("PS", loc("Close"))] {
                let kw = canvas.measure(key, size: 12, weight: .medium).w + 12
                canvas.fill(Box(x: hx, y: box.maxY + 16, w: kw, h: 20), .white(0.12), radius: 4)
                canvas.centred(key, in: Box(x: hx, y: box.maxY + 16, w: kw, h: 20), size: 12, weight: .medium, colour: .white)
                hx += kw + 6 + canvas.label(title, x: hx + kw + 6, midY: box.maxY + 26, size: 12, weight: .medium, colour: .white(0.6)) + 18
            }
        }
    }

    private func drawFocus(_ canvas: Canvas) {
        guard focus.choices.isEmpty, let id = focus.selected, let target = targets.first(where: { $0.id == id }) else { shownFocus = nil; return }
        if id != shownFocus { shownFocus = id; reveal(target.box) }
        guard !id.hasPrefix("game:") else { return }
        let box = target.box
        canvas.save()
        for step in 1...4 { canvas.ring(box, radius: target.corner, outset: 6 + Double(step), width: 2, .black(0.35 / Double(step * 3))) }
        canvas.restore()
        canvas.ring(box, radius: target.corner, outset: 6, width: 3, .white)
    }

    private func reveal(_ box: Box) {
        for region in regions.reversed() where region.box.intersects(Box(x: box.x, y: box.y - 2000, w: box.w, h: 4000)) && box.x >= region.box.x && box.maxX <= region.box.maxX {
            var offset = scrolls[region.name] ?? 0
            if box.y < region.box.y + 20 { offset -= region.box.y + 20 - box.y }
            else if box.maxY > region.box.maxY - 40 { offset += box.maxY - (region.box.maxY - 40) }
            else { continue }
            scrolls[region.name] = max(0, min(offset, max(0, region.content - region.box.h)))
            app.dirty = true
            return
        }
    }

    func pointer(x: Double, y: Double) {
        if let slider = Slider.dragging { slider(x); app.dirty = true; return }
        let over = targets.last { $0.contains(x, y) }?.id
        if over != hover { hover = over; app.dirty = true }
        if stream.phase.isLive { let wasHidden = !controlsShown; controlsUntil = now + 3; if wasHidden { app.dirty = true } }
    }

    func press(x: Double, y: Double, down: Bool) {
        let hit = targets.last { $0.contains(x, y) }
        if down {
            pressed = hit?.id
            if let id = hit?.id, let track = Slider.tracks[id] { Slider.dragging = { px in track.set(max(0, min(1, (px - track.x) / track.w))) }; Slider.dragging?(x) }
            if stream.phase.isLive {
                if hit == nil, stream.hasControls, !stream.menu.isOpen, app.device.captureMouse() { return }
                controlsUntil = now + 3; app.dirty = true
            }
            return
        }
        Slider.dragging = nil
        defer { pressed = nil }
        if searching, hit?.id != LibraryScreen.Target.search { stopSearching() }
        guard let hit, hit.id == pressed else { return }
        hit.action()
        app.dirty = true
    }

    func scroll(x: Double, y: Double, by delta: Double) {
        guard let region = regions.last(where: { $0.box.contains(x, y) }) else { return }
        let offset = (scrolls[region.name] ?? 0) - delta
        scrolls[region.name] = max(0, min(offset, max(0, region.content - region.box.h)))
        app.dirty = true
    }

    func type(_ text: String) {
        if registering != nil || stream.loginPINRequest {
            let limit = registering == nil ? 4 : 8
            code = String((code + text.filter(\.isNumber)).prefix(limit)); app.dirty = true
        } else if searching {
            model.search += text; screen.startOver(); scrolls["library"] = 0
        }
    }

    func key(_ code: UInt16, down: Bool, repeating: Bool) {
        if stream.hasControls {
            if code == Key.f11, down { if !repeating { onFullScreen?() }; return }
            if stream.menu.isOpen, down, code == Key.escape { stream.closeMenu(); return }
            app.device.key(code, down: down)
            return
        }
        guard down else { return }
        if code == Key.f11 { if !repeating { onFullScreen?() }; return }
        if let control = capturingControl {
            guard model.settingsOpen, model.settingsSection == .controller else { capturingControl = nil; return }
            if code == Key.leftSystem || code == Key.rightSystem { return }
            var layout = KeyboardLayout.stored(in: Settings.store)
            layout.assign(code, to: control)
            layout.store(in: Settings.store)
            capturingControl = nil; app.dirty = true
            return
        }
        if registering != nil || stream.loginPINRequest {
            if code == Key.backspace { self.code = String(self.code.dropLast()); app.dirty = true }
            if code == Key.enter, self.code.count == (registering == nil ? 4 : 8) { finishCode() }
            if code == Key.escape, registering != nil { registering = nil; SDLKeyboard.stop(); app.dirty = true }
            return
        }
        if searching {
            if code == Key.backspace { model.search = String(model.search.dropLast()); screen.startOver() }
            if code == Key.enter || code == Key.escape || code == Key.down { stopSearching() }
            return
        }
        if model.loginOpen { if code == Key.escape { model.cancelSignIn(); model.loginOpen = false }; return }
        if !focus.choices.isEmpty {
            let actions: [UInt16: LibraryControllerAction] = [Key.up: .up, Key.down: .down, Key.left: .left, Key.right: .right, Key.enter: .play, Key.escape: .back]
            if let action = actions[code] { _ = focus.handle(action) }
            return
        }
        if model.message != nil, code == Key.enter || code == Key.escape { model.message = nil; return }
        if screen.key(code, text: "") { return }
        if code == Key.escape, screen.gamePageOpen { model.gameOpen = false; screen.gamePageChanged(open: false) }
    }
}

@MainActor enum Slider {
    static var tracks: [String: (x: Double, w: Double, set: (Double) -> Void)] = [:]
    static var dragging: ((Double) -> Void)?
}

