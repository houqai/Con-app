import CCairo
import CConDesktop
import CSDL2
import Foundation
import SoleCore
import SoleEngine
import SoleLogic

func sdl<Value: BinaryInteger>(_ value: Value) -> UInt32 { UInt32(truncatingIfNeeded: value) }

@MainActor final class Shell {
    static var shared: Shell?
    let app: DesktopApp
    let screens: Screens
    private let window: OpaquePointer
    private let renderer: OpaquePointer
    private var overlay: OpaquePointer?
    private var overlaySize = (w: Int32(0), h: Int32(0))
    private var controller: OpaquePointer?
    private var lastDraw = 0.0
    private var wasStreaming = false
    private let snapshot: (file: String, at: Double)? = {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshot"), arguments.count > index + 1 else { return nil }
        let seconds = arguments.count > index + 2 ? Double(arguments[index + 2]) ?? 20 : 20
        return (arguments[index + 1], ProcessInfo.processInfo.systemUptime + seconds)
    }()

    static func start() {
        SDL_SetHint(SDL_HINT_VIDEO_X11_NET_WM_BYPASS_COMPOSITOR, "0")
        SDL_SetHint("SDL_JOYSTICK_HIDAPI_PS5_RUMBLE", "1")
        SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "linear")
        SDL_SetYUVConversionMode(SDL_YUV_CONVERSION_BT709)
        SDL_SetHint("SDL_WINDOWS_INTRESOURCE_ICON", "1")
        SDL_SetHint("SDL_BORDERLESS_RESIZABLE_STYLE", "1")
        SDL_SetHint("SDL_BORDERLESS_WINDOWED_STYLE", "1")
        guard SDL_Init(sdl(SDL_INIT_VIDEO | SDL_INIT_AUDIO | SDL_INIT_GAMECONTROLLER)) == 0 else {
            logLine("Con: SDL could not start: \(String(cString: SDL_GetError()))"); exit(1)
        }
        shared = Shell()
    }

    private init() {
        let flags = sdl(SDL_WINDOW_RESIZABLE.rawValue | SDL_WINDOW_ALLOW_HIGHDPI.rawValue | (Steam.gameMode ? 0 : SDL_WINDOW_BORDERLESS.rawValue))
        window = SDL_CreateWindow("Con", Int32(SDL_WINDOWPOS_CENTERED_MASK), Int32(SDL_WINDOWPOS_CENTERED_MASK), 1280, 800, flags)
        #if os(Windows)
        SDL_SetHint(SDL_HINT_RENDER_DRIVER, "direct3d11")
        #endif
        renderer = SDL_CreateRenderer(window, -1, sdl(SDL_RENDERER_ACCELERATED.rawValue | SDL_RENDERER_PRESENTVSYNC.rawValue))
            ?? SDL_CreateRenderer(window, -1, sdl(SDL_RENDERER_SOFTWARE.rawValue))
        SDL_SetWindowMinimumSize(window, 640, 400)
        if Steam.gameMode { SDL_SetWindowFullscreen(window, sdl(SDL_WINDOW_FULLSCREEN_DESKTOP.rawValue)) }
        app = DesktopApp()
        let ways = con_video_upscale_methods(renderer)
        app.device.upscaleMethods = [(1, Upscale.Method.fsr), (2, .nis), (4, .anime4k)].filter { ways & $0.0 != 0 }.map(\.1)
        screens = Screens(app: app)
        app.device.onFullScreen = { [weak self] in self?.toggleFullScreen() }
        app.device.displayIndex = { [weak self] in self.map { max(0, SDL_GetWindowDisplayIndex($0.window)) } ?? 0 }
        app.device.rumble = { [weak self] low, high, milliseconds in
            if let pad = self?.controller { SDL_GameControllerRumble(pad, low, high, milliseconds) }
        }
        app.device.effects = { [weak self] effects in
            guard let pad = self?.controller, SDL_GameControllerGetType(pad) == SDL_CONTROLLER_TYPE_PS5 else { return false }
            return effects.withUnsafeBufferPointer { SDL_GameControllerSendEffect(pad, $0.baseAddress, Int32($0.count)) } == 0
        }
        Pictures.shared.arrived = { [weak self] in self?.app.dirty = true }
        screens.onFullScreen = { [weak self] in self?.toggleFullScreen() }
        if !Steam.gameMode {
            SDL_SetWindowHitTest(window, { _, point, _ in
                guard let point else { return SDL_HITTEST_NORMAL }
                let x = Double(point.pointee.x), y = Double(point.pointee.y)
                return MainActor.assumeIsolated { Shell.shared?.hitTest(x: x, y: y) ?? SDL_HITTEST_NORMAL }
            }, nil)
            screens.windowControls = (
                fullScreen: { [weak self] in self?.fullScreen ?? false },
                maximized: { [weak self] in self?.maximized ?? false },
                act: { [weak self] action in self?.windowAction(action) })
            con_window_round_corners()
        }
        screens.isFullScreen = { [weak self] in self?.fullScreen ?? false }
        openController()
    }

    private var fullScreen: Bool { SDL_GetWindowFlags(window) & sdl(SDL_WINDOW_FULLSCREEN_DESKTOP.rawValue) != 0 }
    private var maximized: Bool { SDL_GetWindowFlags(window) & sdl(SDL_WINDOW_MAXIMIZED.rawValue) != 0 }

    private func windowAction(_ action: Screens.WindowAction) {
        switch action {
        case .fullScreen: toggleFullScreen()
        case .minimize: SDL_MinimizeWindow(window)
        case .maximize:
            if maximized { SDL_RestoreWindow(window) } else { SDL_MaximizeWindow(window) }
        case .close:
            var quit = SDL_Event(); quit.type = sdl(SDL_QUIT.rawValue)
            SDL_PushEvent(&quit)
        }
        app.dirty = true
    }

    func hitTest(x: Double, y: Double) -> SDL_HitTestResult {
        guard !fullScreen else { return SDL_HITTEST_NORMAL }
        var w: Int32 = 0, h: Int32 = 0
        SDL_GetWindowSize(window, &w, &h)
        let edge = 8.0, width = Double(w), height = Double(h)
        if !maximized {
            let left = x < edge, right = x >= width - edge, top = y < edge, bottom = y >= height - edge
            switch (left, right, top, bottom) {
            case (true, _, true, _): return SDL_HITTEST_RESIZE_TOPLEFT
            case (_, true, true, _): return SDL_HITTEST_RESIZE_TOPRIGHT
            case (true, _, _, true): return SDL_HITTEST_RESIZE_BOTTOMLEFT
            case (_, true, _, true): return SDL_HITTEST_RESIZE_BOTTOMRIGHT
            case (true, _, _, _): return SDL_HITTEST_RESIZE_LEFT
            case (_, true, _, _): return SDL_HITTEST_RESIZE_RIGHT
            case (_, _, true, _): return SDL_HITTEST_RESIZE_TOP
            case (_, _, _, true): return SDL_HITTEST_RESIZE_BOTTOM
            default: break
            }
        }
        return screens.draggable(x: x, y: y) ? SDL_HITTEST_DRAGGABLE : SDL_HITTEST_NORMAL
    }

    private func toggleFullScreen() {
        SDL_SetWindowFullscreen(window, fullScreen ? 0 : sdl(SDL_WINDOW_FULLSCREEN_DESKTOP.rawValue))
        app.dirty = true
    }

    private func openController() {
        guard controller == nil else { return }
        for index in 0..<SDL_NumJoysticks() where SDL_IsGameController(index) == SDL_TRUE {
            controller = SDL_GameControllerOpen(index)
            if controller != nil { screens.padName = String(cString: SDL_GameControllerName(controller)); break }
        }
    }

    func turn() -> Bool {
        var event = SDL_Event()
        let streaming = app.stream.phase.isLive
        if wasStreaming, !streaming, fullScreen, !Steam.gameMode { toggleFullScreen() }
        wasStreaming = streaming
        while SDL_PollEvent(&event) != 0 { handle(event) }
        readController()
        app.device.tickMouse()
        app.tick()
        let drew = draw(streaming: streaming)
        return !drew && !streaming
    }

    private func draw(streaming: Bool) -> Bool {
        var w: Int32 = 0, h: Int32 = 0, pw: Int32 = 0, ph: Int32 = 0
        SDL_GetWindowSize(window, &w, &h)
        SDL_GetRendererOutputSize(renderer, &pw, &ph)
        let scale = w > 0 ? Double(pw) / Double(w) : 1
        let now = ProcessInfo.processInfo.systemUptime
        let snapshotDue = snapshot.map { now >= $0.at } ?? false
        let redraw = snapshotDue || app.dirty || overlay == nil || overlaySize != (pw, ph) || (streaming && now - lastDraw > 0.5) || screens.animating || now >= screens.blinkDue
        if redraw {
            app.dirty = false
            lastDraw = now
            let surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, pw, ph)!
            let cairo = cairo_create(surface)!
            let canvas = Canvas(cairo: cairo, scale: scale)
            screens.draw(canvas, width: Double(w), height: Double(h), now: now)
            cairo_surface_flush(surface)
            if snapshotDue, let snapshot {
                let written = cairo_surface_write_to_png(surface, snapshot.file)
                logLine("snapshot: \(written == CAIRO_STATUS_SUCCESS ? "written" : "failed") \(pw)x\(ph)")
                exit(written == CAIRO_STATUS_SUCCESS ? 0 : 1)
            }
            if overlay == nil || overlaySize != (pw, ph) {
                if let overlay { SDL_DestroyTexture(overlay) }
                overlay = SDL_CreateTexture(renderer, sdl(SDL_PIXELFORMAT_ARGB8888.rawValue), Int32(SDL_TEXTUREACCESS_STREAMING.rawValue), pw, ph)
                SDL_SetTextureBlendMode(overlay, SDL_BLENDMODE_BLEND)
                overlaySize = (pw, ph)
            }
            SDL_UpdateTexture(overlay, nil, cairo_image_surface_get_data(surface), cairo_image_surface_get_stride(surface))
            cairo_destroy(cairo)
            cairo_surface_destroy(surface)
            app.places(screens.targets)
        }
        guard redraw || streaming else { return false }
        SDL_ShowCursor(streaming && !screens.controlsShown ? SDL_DISABLE : SDL_ENABLE)
        SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255)
        SDL_RenderClear(renderer)
        if screens.showsPicture {
            con_video_draw(renderer, 0, 0, pw, ph, app.model.videoFit == AppModel.fill ? 1 : 0)
        }
        SDL_RenderCopy(renderer, overlay, nil, nil)
        SDL_RenderPresent(renderer)
        return true
    }

    private func handle(_ event: SDL_Event) {
        switch SDL_EventType(numericCast(event.type)) {
        case SDL_QUIT:
            app.page.cancel(); app.stream.shutDown(); app.stream.disconnect(); app.model.cancelCloud()
            exit(0)
        case SDL_WINDOWEVENT:
            if event.window.event == UInt8(SDL_WINDOWEVENT_FOCUS_LOST.rawValue) { app.take(nil); app.device.releaseMouse() }
            app.dirty = true
        case SDL_MOUSEMOTION:
            if app.device.mouseCaptured { app.device.mouseMoved(dx: Double(event.motion.xrel), dy: Double(event.motion.yrel)); return }
            screens.pointer(x: Double(event.motion.x), y: Double(event.motion.y))
        case SDL_MOUSEBUTTONDOWN, SDL_MOUSEBUTTONUP:
            let down = event.type == SDL_MOUSEBUTTONDOWN.rawValue
            if app.device.mouseCaptured {
                if event.button.button == UInt8(SDL_BUTTON_LEFT) || event.button.button == UInt8(SDL_BUTTON_RIGHT) {
                    app.device.mouseButton(left: event.button.button == UInt8(SDL_BUTTON_LEFT), down: down)
                }
                return
            }
            screens.press(x: Double(event.button.x), y: Double(event.button.y), down: down)
        case SDL_MOUSEWHEEL:
            var x: Int32 = 0, y: Int32 = 0
            SDL_GetMouseState(&x, &y)
            screens.scroll(x: Double(x), y: Double(y), by: Double(event.wheel.y) * 60)
        case SDL_TEXTINPUT:
            let text = withUnsafeBytes(of: event.text.text) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            screens.type(text)
        case SDL_KEYDOWN, SDL_KEYUP:
            let down = event.type == SDL_KEYDOWN.rawValue
            let code = event.key.keysym.scancode
            if !Steam.gameMode, down, event.key.repeat == 0, code == SDL_SCANCODE_F11 { toggleFullScreen(); return }
            screens.key(UInt16(code.rawValue), down: down, repeating: event.key.repeat != 0)
        case SDL_CONTROLLERDEVICEADDED:
            openController(); app.dirty = true
        case SDL_CONTROLLERDEVICEREMOVED:
            if let controller, SDL_GameControllerGetAttached(controller) == SDL_FALSE {
                SDL_GameControllerClose(controller); self.controller = nil; screens.padName = nil
                app.take(nil)
            }
            openController(); app.dirty = true
        default: break
        }
    }

    private var lastReading: PadReading?
    private func readController() {
        guard let pad = controller else { return }
        var reading = PadReading()
        let buttons: [(SDL_GameControllerButton, ControllerState.Button)] = [
            (SDL_CONTROLLER_BUTTON_A, .cross), (SDL_CONTROLLER_BUTTON_B, .circle), (SDL_CONTROLLER_BUTTON_X, .square), (SDL_CONTROLLER_BUTTON_Y, .triangle),
            (SDL_CONTROLLER_BUTTON_LEFTSHOULDER, .l1), (SDL_CONTROLLER_BUTTON_RIGHTSHOULDER, .r1),
            (SDL_CONTROLLER_BUTTON_LEFTSTICK, .l3), (SDL_CONTROLLER_BUTTON_RIGHTSTICK, .r3),
            (SDL_CONTROLLER_BUTTON_START, .options), (SDL_CONTROLLER_BUTTON_BACK, .share), (SDL_CONTROLLER_BUTTON_GUIDE, .ps),
            (SDL_CONTROLLER_BUTTON_TOUCHPAD, .touchpad),
            (SDL_CONTROLLER_BUTTON_DPAD_UP, .dpadUp), (SDL_CONTROLLER_BUTTON_DPAD_DOWN, .dpadDown),
            (SDL_CONTROLLER_BUTTON_DPAD_LEFT, .dpadLeft), (SDL_CONTROLLER_BUTTON_DPAD_RIGHT, .dpadRight),
        ]
        for (sdl, button) in buttons where SDL_GameControllerGetButton(pad, sdl) != 0 { reading.buttons.insert(button) }
        func axis(_ which: SDL_GameControllerAxis) -> Float {
            let value = Float(SDL_GameControllerGetAxis(pad, which)) / 32767
            return abs(value) < 0.08 ? 0 : max(-1, min(1, value))
        }
        reading.leftX = axis(SDL_CONTROLLER_AXIS_LEFTX); reading.leftY = -axis(SDL_CONTROLLER_AXIS_LEFTY)
        reading.rightX = axis(SDL_CONTROLLER_AXIS_RIGHTX); reading.rightY = -axis(SDL_CONTROLLER_AXIS_RIGHTY)
        reading.l2 = max(0, axis(SDL_CONTROLLER_AXIS_TRIGGERLEFT)); reading.r2 = max(0, axis(SDL_CONTROLLER_AXIS_TRIGGERRIGHT))
        if reading != lastReading {
            lastReading = reading
            app.take(reading)
            screens.padHeld = reading.heldText
            if app.model.settingsOpen { app.dirty = true }
        }
    }
}
