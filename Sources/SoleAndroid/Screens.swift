import CConAndroid
import Foundation
import SoleCloud
import SoleCore
import SoleEngine
import SoleLogic

extension AndroidApp {
    static func colour(_ hue: Double, lightness: Double = 0.42, chroma: Double = 0.11) -> Int {
        let rgb = ColorWheel.rgb(hue: hue, lightness: lightness, chroma: chroma)
        func byte(_ value: Double) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
        return Int(bitPattern: 0xFF00_0000) | byte(rgb.red) << 16 | byte(rgb.green) << 8 | byte(rgb.blue)
    }

    static func tile(_ game: Game) -> [String: Any] {
        ["id": game.id, "title": game.title, "art": game.artworkURL?.absoluteString ?? NSNull(), "fav": game.favorite, "tint": colour(game.hue)]
    }

    static func page(_ game: Game) -> [String: Any] {
        var page = tile(game)
        page["kicker"] = ([game.platform] + game.genres.prefix(1).map(Game.genreName)).joined(separator: " · ").uppercased()
        page["store"] = game.storeURL?.absoluteString ?? NSNull()
        page["backdrop"] = colour(game.hue, lightness: 0.4, chroma: 0.12)
        return page
    }

    static func name(_ item: StreamMenu.Item) -> String {
        switch item {
        case .restart: return "restart"
        case .resume: return "resume"
        case .stats: return "stats"
        case .generation: return "generation"
        case .upscaler: return "upscaler"
        case .upscaleAmount: return "upscaleAmount"
        case .upscaleMethod: return "upscaleMethod"
        case .fullScreen: return "fullScreen"
        case .leave: return "leave"
        }
    }

    func choices(of select: String) -> (values: [(String, String)], chosen: String, apply: (String) -> Void)? {
        let model = self.model
        switch select {
        case "app-language":
            return (AppLanguage.allCases.map { ($0.rawValue, $0.name) }, model.language, { model.language = $0 })
        case "catalog-locale":
            return (CatalogRegion.choices, model.catalogLocale, { model.catalogLocale = $0; model.reloadCatalog() })
        case "video-fit":
            return ([("fit", loc("Fit")), (AppModel.fill, loc("Fill"))], model.videoFit, { model.videoFit = $0 })
        case "datacenter":
            return (model.datacenterChoices, model.selectedDatacenter, { model.selectedDatacenter = $0 })
        case "game-language":
            return (GameLanguage.all.map { ($0.code, $0.name) }, model.gameLanguage, { model.gameLanguage = $0 })
        case "smoothness":
            return (Smoothness.choices(byRefresh: true).map { (String($0.0), $0.1) }, String(Smoothness.read(.standard)),
                    { [weak self] in UserDefaults.standard.set(Int($0) ?? Smoothness.standard, forKey: Smoothness.key); self?.changed() })
        default: return nil
        }
    }

    func picture() -> [String: Any] {
        var drawn: Int32 = 0, width: Int32 = 0, height: Int32 = 0, sound: Int32 = 0, refused: Int32 = 0
        con_video_counts(&drawn, &width, &height)
        con_audio_counts(&sound, &refused)
        let games = screen.games
        var state: [String: Any] = [
            "account": model.account?.displayName ?? NSNull(), "avatar": model.account?.avatarURL?.absoluteString ?? NSNull(), "plus": model.account?.isPlus ?? NSNull(),
            "restoring": model.restoringAccount, "signingIn": model.signingIn, "signingOut": model.signingOut,
            "authError": model.authError ?? NSNull(), "message": model.message ?? NSNull(), "loginOpen": model.loginOpen,
            "catalogue": model.catalogGames.count, "loadingCatalog": model.loadingCatalog, "catalogError": model.catalogError ?? NSNull(),
            "history": model.games.count, "loadingLibrary": model.loadingLibrary, "libraryError": model.libraryError ?? NSNull(),
            "owned": !model.owned.isEmpty, "loadingOwned": model.loadingOwned,
            "destination": model.destination == .cloud ? "cloud" : "consoles", "consolesShown": Destination.consolesShown,
            "backend": model.catalogBackend.rawValue, "filter": model.filter.rawValue, "search": model.search,
            "filters": model.availableLibraryFilters.map { [$0.rawValue, loc($0.rawValue)] },
            "count": model.filteredGames.count, "countText": loc("%@ games", model.filteredGames.count),
            "tiles": games.prefix(screen.visibleCount).map(Self.tile), "more": screen.hasMore,
            "empty": model.filteredGames.isEmpty ? screen.emptyText : NSNull(),
            "error": model.catalogError ?? model.pcCatalogError ?? model.libraryError ?? NSNull(),
            "chosen": model.selectedGame?.id ?? NSNull(),
            "glow": [Self.colour(screen.game?.hue ?? 100, lightness: 0.45, chroma: 0.16), Self.colour((screen.game?.hue ?? 100) + 40, lightness: 0.32, chroma: 0.12)],
            "gameOpen": screen.gamePageOpen, "page": screen.gamePageOpen ? screen.game.map(Self.page) ?? NSNull() : NSNull(),
            "listed": games.prefix(60).map(\.title), "listedIDs": games.prefix(60).map(\.id), "listedCount": games.count,
            "language": model.language,
            "launching": screen.launching, "connecting": model.connectingCloud,
            "launchGame": (model.cloudLaunchingGame ?? screen.game).map(Self.page) ?? NSNull(),
            "cloudStatus": model.cloudStatus ?? NSNull(), "cloudError": model.cloudError ?? NSNull(), "canRetry": model.cloudCanRetry,
            "phase": Self.name(stream.phase), "streamStatus": stream.statusText ?? NSNull(), "statsVisible": stream.statsVisible,
            "panel": stream.stats.map(StreamPanel.summary) ?? NSNull(),
            "surface": con_video_ready() != 0,
            "drawn": Int(drawn), "size": "\(width)x\(height)", "sound": Int(sound), "soundLeftOut": Int(refused),
            "soundHeard": AndroidMedia.heard, "soundPeak": AndroidMedia.peak, "soundDry": Int(con_audio_underruns()),
            "framesLost": stream.stats?.lostFrames ?? 0, "framesHeld": stream.stats?.decodeFailures ?? 0,
            "framesHidden": stream.stats?.hiddenFrames ?? 0, "hiddenRuns": stream.stats?.hiddenRuns ?? 0, "framesBridged": stream.stats?.bridgedLosses ?? 0,
            "focus": focus.choices.isEmpty ? focus.selected ?? NSNull() : NSNull(),
            "choices": focus.choices.map(\.title), "choiceIndex": focus.choiceIndex,
            "held": pad.map { $0.heldText } ?? NSNull(),
        ]
        state["cells"] = stream.stats.map { stats in
            [StreamPanel.Detail.full, .less, .least].map { detail in
                StreamPanel.cells(stats, detail: detail).map { cell -> [String: Any] in
                    let tint = cell.trouble.color
                    return ["kind": cell.kind.rawValue, "value": cell.value, "unit": cell.unit ?? NSNull(),
                            "tint": Int(bitPattern: 0xFF00_0000) | Int((tint.red * 255).rounded()) << 16 | Int((tint.green * 255).rounded()) << 8 | Int((tint.blue * 255).rounded())]
                }
            }
        } ?? NSNull()
        state["trophy"] = stream.trophyNotice.map { notice -> [String: Any] in
            let grade = AccountPage.Grade(notice.grade).color
            return ["id": notice.id, "heading": notice.heading, "title": notice.title, "icon": notice.iconURL?.absoluteString ?? NSNull(),
                    "tint": Int(bitPattern: 0xFF00_0000) | Int((grade.red * 255).rounded()) << 16 | Int((grade.green * 255).rounded()) << 8 | Int((grade.blue * 255).rounded())]
        } ?? NSNull()
        state["menu"] = menuPicture()
        state["settings"] = settingsPicture()
        state["consoles"] = consolesPicture()
        state["t"] = Self.texts()
        return state
    }

    private func menuPicture() -> [String: Any] {
        let menu = stream.menu
        var picture: [String: Any] = ["open": menu.isOpen, "selection": menu.selection]
        picture["notice"] = stream.silentSound ? loc("The server sent the game without sound") : NSNull()
        picture["items"] = menu.items.map { item -> [String: Any] in
            let on = item.isOn(statsVisible: stream.statsVisible, generation: stream.frameGeneration, upscaling: stream.upscaling)
            return ["id": Self.name(item), "title": item.title(fullScreen: true), "state": on.map(StreamMenu.Item.stateText) ?? NSNull(), "on": on ?? NSNull()]
        }
        let game = stream.streamGame
        picture["title"] = game?.title ?? StreamGame.unknownTitle
        picture["platform"] = game?.platform ?? NSNull()
        picture["art"] = game?.artwork?.absoluteString ?? NSNull()
        picture["facts"] = (stream.stats?.facts ?? []).joined(separator: " · ")
        picture["minutes"] = stream.stats.map { loc("Playing for %@ min", max(1, $0.seconds / 60)) } ?? NSNull()
        if let stats = stream.stats, let delay = stats.delayMs, let ping = stats.livePingMs ?? stats.measuredPingMs {
            picture["delay"] = loc("Delay ≈ %@ ms: network %@ + phone %@", delay, ping, delay - ping)
        }
        return picture
    }

    private func settingsPicture() -> [String: Any] {
        var selects: [String: String] = [:]
        for name in ["app-language", "catalog-locale", "video-fit", "datacenter", "game-language", "smoothness"] {
            guard let list = choices(of: name) else { continue }
            selects[name] = list.values.first { $0.0 == list.chosen }?.1 ?? list.chosen
        }
        return [
            "open": model.settingsOpen, "section": model.settingsSection.id,
            "sections": SettingsSection.allCases.map { [$0.id, loc($0.rawValue)] },
            "selects": selects, "fit": model.videoFit, "resolution": model.resolution, "bitrate": Int(model.bitrate),
            "bitrateText": loc("%@ Mbps", Int(model.bitrate)), "haptics": model.haptics, "trophyNotices": model.trophyNotices, "distantServers": model.distantServers, "touchGamepad": model.touchGamepad,
            "presets": StreamQuality.heights.map { [$0, StreamQuality.name(height: $0), StreamQuality.note(height: $0)] },
            "datacenters": !model.datacenters.isEmpty,
            "datacenterCaption": model.datacenterCaption,
            "datacenterNote": model.datacenterNote,
            "accountNote": model.restoringAccount ? loc("Restoring your saved sign-in…") : model.account == nil ? loc("Sign in to open your game library.") : loc("Account connected"),
            "accountButton": model.restoringAccount ? loc("Restoring sign-in…") : model.account == nil ? loc("Connect account") : loc("Sign out"),
            "accountPage": accountPagePicture(),
        ]
    }

    private func accountPagePicture() -> [String: Any] {
        let page = AccountPage(model)
        guard page.shown else { return ["shown": false] }
        func argb(_ colour: (red: Double, green: Double, blue: Double)) -> Int {
            func byte(_ value: Double) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
            return Int(bitPattern: 0xFF00_0000) | byte(colour.red) << 16 | byte(colour.green) << 8 | byte(colour.blue)
        }
        var picture: [String: Any] = ["shown": true, "trophyNote": page.trophyNote ?? NSNull(), "recentNote": page.recentNote ?? NSNull(),
                                      "gold": argb(AccountPage.Grade.gold.color)]
        if let trophies = page.trophies {
            picture["level"] = page.levelText ?? ""
            picture["progress"] = trophies.summary.progress
            picture["progressText"] = page.progressText ?? ""
            picture["grades"] = page.grades.map { ["title": $0.grade.title, "count": $0.count, "tint": argb($0.grade.color)] as [String: Any] }
        }
        picture["titles"] = page.trophyTitles.map { title -> [String: Any] in
            ["name": title.name, "note": AccountPage.trophyTitleNote(title), "icon": title.iconURL?.absoluteString ?? NSNull(), "progress": title.progress]
        }
        picture["recent"] = page.recent.map { recent -> [String: Any] in
            var tile = Self.tile(recent.game)
            tile["id"] = recent.id
            tile["played"] = page.lastPlayedText(recent) ?? NSNull()
            return tile
        }
        return picture
    }

    private func consolesPicture() -> [String: Any] {
        func state(_ state: DiscoveredConsole.State) -> [Any] {
            switch state {
            case .ready: return [loc("Ready"), 0]
            case .standby: return [loc("Rest mode"), 1]
            case .unknown: return [loc("Unknown"), 2]
            }
        }
        var failure: Any = NSNull()
        if case .failed(let reason) = stream.phase { failure = reason }
        return [
            "found": stream.consoles.map { console -> [String: Any] in
                ["id": console.id, "name": console.name.isEmpty ? console.address : console.name, "ps5": console.isPS5,
                 "state": state(console.state), "registered": stream.isRegistered(console.id)]
            },
            "offline": stream.offlineRegistered.map { ["id": $0.hostID, "name": $0.name, "ps5": $0.isPS5] },
            "status": stream.statusText ?? NSNull(), "failure": failure, "busy": stream.phase.isBusy,
            "pinRequest": stream.loginPINRequest,
        ]
    }

    static func texts() -> [String: String] {
        [
            "cloudGames": loc("Cloud games"), "consoles": loc("My consoles"), "search": loc("Search games"),
            "reload": loc("Refresh library"), "settings": loc("Settings"), "signInShort": loc("Sign in"), "connected": loc("Connected"),
            "catalogue": loc("Cloud catalog"), "more": loc("Show more"), "back": loc("Catalog"),
            "play": loc("Play"), "favorite": loc("Add to favorites"), "favorited": loc("In favorites"), "store": loc("PS Store"),
            "screenshots": loc("Screenshots"), "checking": loc("Checking access to the game…"), "cancel": loc("Cancel"), "close": loc("Close"),
            "understood": loc("OK"),
            "connectPS": loc("Connect PlayStation"), "oneSignIn": loc("One sign-in for the library and the cloud."),
            "signInSony": loc("Sign in on Sony's website.\nSony offers the sign-in methods, including QR."), "signInButton": loc("Sign in on Sony's website"),
            "waiting": loc("Waiting for sign-in…"), "cancelSignIn": loc("Cancel sign-in"), "passwordNote": loc("Your password is entered only on Sony's website."),
            "appLanguage": loc("App language"), "appLanguageCaption": loc("The language of Con's interface"),
            "region": loc("Catalog region"), "regionCaption": loc("Sony's list of games · not the datacenter choice"),
            "fit": loc("Picture size"), "fitCaption": loc("How the video fills the screen"),
            "yourAccount": loc("Your PlayStation account"), "refreshSignIn": loc("Refresh sign-in"),
            "accountFooter": loc("You sign in on the PlayStation page. Con never asks for your password in forms of its own."),
            "even": loc("Smooth presentation"), "evenCaption": loc("How long a frame waits for an even rhythm. Less is sooner on screen, but less even on an uneven network"),
            "quality": loc("Video quality"), "bitrate": loc("Bitrate"), "bitrateCaption": loc("Higher means more detail and more data used"),
            "datacenter": loc("Datacenter"), "retry": loc("Connect again"),
            "gameLanguage": loc("Game language"), "gameLanguageCaption": loc("If the game supports it"),
            "haptics": loc("Vibration"), "hapticsCaption": loc("Feedback in games that support it"),
            "trophyNotices": loc("Trophy notifications"), "trophyNoticesCaption": loc("Show trophies earned over the game"),
            "distantServers": loc("Distant servers"), "distantServersCaption": loc("Reports a lower latency to Sony so that a server further than 80 ms is accepted. This breaks Sony's rules: at your own risk"),
            "touchGamepad": loc("On-screen gamepad"), "touchGamepadCaption": loc("Buttons over the stream while no gamepad is connected"),
            "background": loc("The stream is on. Tap to go back to it."),
            "noPad": loc("No controller connected"),
            "noPadNote": loc("Connect a DualSense, DualShock or another compatible gamepad to the phone over USB or Bluetooth. Con finds it on its own."),
            "padNote": loc("During a stream the connected gamepad controls the game."),
            "tagline": loc("Your games. Your phone."), "version": loc("Version %@"), "aboutNote": loc("Cloud games and connection to your PlayStation."),
            "licenses": loc("Licenses"), "trophies": loc("Trophies"), "recentGames": loc("Recent games"),
            "consolesTitle": loc("Your PlayStation. Right here."), "consolesNote": loc("Connect to your console and pick up where you left off."),
            "consolesSignIn": loc("Sign in to PlayStation to register consoles and start Remote Play."), "connectPSButton": loc("Connect PlayStation"),
            "local": loc("On the local network"),
            "searching": loc("Looking for PlayStation consoles on the network. Make sure your PS5 or PS4 is on, is on the same network, and has Remote Play enabled in its settings."),
            "saved": loc("Saved"), "offline": loc("Offline"), "remove": loc("Remove"), "pair": loc("Connect"), "unregister": loc("Remove registration"),
            "remoteNote": loc("Remote Play connects directly to your console on the local network. It is separate from cloud streaming."),
            "registration": loc("Register %@"),
            "pairSteps": loc("On the console, open Settings → System → Remote Play → Link Device and enter the 8-digit code shown."),
            "pinHint": loc("8-digit code"), "register": loc("Register"),
            "loginPin": loc("Console login code"), "loginPinNote": loc("The console asked for the account login code. Enter it to continue."),
            "pinShort": loc("Code"), "confirm": loc("Confirm"),
            "leave": loc("Disconnect"), "connecting": loc("Connecting…"), "statsShow": loc("Show stream stats"),
            "statsHide": loc("Hide stream stats"), "menu": loc("Menu"),
            "choose": loc("Select"), "goBack": loc("Back"),
        ]
    }

    func act(_ name: String, _ value: String) {
        switch name {
        case "destination": model.destination = value == "consoles" ? .consoles : .cloud
        case "backend":
            guard let backend = CloudBackend(rawValue: value), backend != model.catalogBackend else { return }
            model.catalogBackend = backend; screen.catalogReplaced()
        case "filter":
            guard let filter = LibraryFilter(rawValue: value), filter != model.filter else { return }
            model.filter = filter; screen.startOver()
        case "search":
            guard value != model.search else { return }
            model.search = value; screen.startOver()
        case "columns": if let count = Int(value), count > 0 { screen.columns = count }
        case "more": screen.showMore()
        case "reload": model.reloadCatalog(force: true); model.reloadLibrary()
        case "open":
            guard let game = screen.games.first(where: { $0.id == value }) else { return }
            model.openGame(game); screen.gamePageChanged(open: true)
        case "closePage": model.gameOpen = false; screen.gamePageChanged(open: false)
        case "favorite": model.toggleFavorite(value.isEmpty ? model.selectedGame?.id ?? "" : value)
        case "play":
            guard let game = screen.games.first(where: { $0.id == value }) ?? (screen.game?.id == value ? screen.game : nil) else { return }
            screen.play(game)
        case "cancelLaunch": screen.cancelLaunch(); stream.disconnect()
        case "retry": model.connectCloud()
        case "settings":
            model.showSettings(SettingsSection.allCases.first { $0.id == value } ?? .general); screen.settingsChanged(open: true)
        case "closeSettings": model.settingsOpen = false; screen.settingsChanged(open: false)
        case "section": if let section = SettingsSection.allCases.first(where: { $0.id == value }) { model.settingsSection = section }
        case "message": model.message = nil
        case "openRecent": screen.openRecent(value)
        case "select":
            guard let list = choices(of: value) else { return }
            focus.choiceIndex = list.values.firstIndex { $0.0 == list.chosen } ?? 0
            focus.choices = list.values.map { pair in FocusModel.Choice(title: pair.1, action: { list.apply(pair.0) }) }
        case "headerMenu":
            let screen = self.screen
            focus.choiceIndex = 0
            focus.choices = screen.destinationChoices + screen.appChoices(settingsOpened: { screen.settingsChanged(open: true) })
        case "choice":
            guard let index = Int(value), focus.choices.indices.contains(index) else { focus.choices = []; return }
            let choice = focus.choices[index]; focus.choices = []; choice.action()
        case "preset": if let height = Int(value) { model.selectPreset(height) }
        case "bitrate": if let rate = Double(value) { model.bitrate = StreamQuality.clampedBitrate(rate.rounded()) }
        case "haptics": model.haptics = value == "1"
        case "trophyNotices": model.trophyNotices = value == "1"
        case "distantServers": model.distantServers = value == "1"
        case "touchGamepad": model.touchGamepad = value == "1"
        case "loginOpen": model.loginOpen = value == "1"; if value != "1" { model.cancelSignIn() }
        case "signIn": model.signIn()
        case "cancelSignIn": model.cancelSignIn()
        case "signOut": model.signOut()
        case "press":
            let actions: [String: LibraryControllerAction] = ["left": .left, "right": .right, "up": .up, "down": .down, "play": .play, "back": .back, "favorite": .favorite, "settings": .settings]
            if let action = actions[value] { screen.handle(action) }
        case "targets": takeTargets(value)
        case "stats": stream.statsVisible.toggle()
        case "openMenu": stream.openMenu()
        case "menuChoose": if let item = stream.menu.items.first(where: { Self.name($0) == value }) { stream.choose(item) }
        case "menuPoint": if let item = stream.menu.items.first(where: { Self.name($0) == value }) { stream.pointMenu(at: item) }
        case "menuClose": stream.closeMenu()
        case "leave": model.cancelCloud(); stream.disconnect()
        case "register":
            let parts = value.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let console = stream.consoles.first(where: { $0.id == parts[0] }) else { return }
            Task { await stream.register(console: console, pin: parts[1]) }
        case "connectConsole":
            guard let console = stream.consoles.first(where: { $0.id == value }) else { return }
            Task { await stream.connect(console: console) }
        case "removeConsole": stream.removeRegistration(hostID: value)
        case "clearFailure": stream.clearFailure()
        case "loginPin": stream.submitLoginPIN(value)
        case "deviceLanguage":
            guard UserDefaults.standard.string(forKey: AppLanguage.storageKey) == nil, let language = AppLanguage(rawValue: value) else { return }
            model.language = language.rawValue
        default: break
        }
    }

    private func takeTargets(_ text: String) {
        var places: [FocusTarget] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count >= 3, let x = Double(parts[parts.count - 2]), let y = Double(parts[parts.count - 1]) else { continue }
            let id = parts.dropLast(2).joined(separator: " ")
            var target = FocusTarget(id: id, at: (x, y), activate: { con_java_activate(id) })
            if id == "bitrate" { target.adjust = { [model] step in model.bitrate = StreamQuality.clampedBitrate(model.bitrate + Double(step)) } }
            places.append(target)
        }
        focus.update(places)
    }

    static func screenshots(of id: String) async -> [String] {
        let found: (Game, AppModel)? = await MainActor.run {
            guard let app = AndroidApp.shared, let game = app.screen.game, game.id == id else { return nil }
            return (game, app.model)
        }
        guard let (game, model) = found else { return [] }
        return await model.screenshots(for: game).map(\.absoluteString)
    }
}
