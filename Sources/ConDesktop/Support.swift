import CCairo
import CConDesktop
import CSDL2
import Foundation
#if os(Windows)
import WinSDK
#endif

func logLine(_ line: String) {
    try? FileHandle.standardError.write(contentsOf: Data((line + "\n").utf8))
}

enum Program {
    #if os(Windows)
    static let windows = true
    #else
    static let windows = false
    #endif

    static let folder: URL = {
        #if os(Windows)
        var path = [WCHAR](repeating: 0, count: 32768)
        let length = Int(GetModuleFileNameW(nil, &path, DWORD(path.count)))
        return URL(fileURLWithPath: String(decoding: path.prefix(length), as: UTF16.self)).deletingLastPathComponent()
        #else
        if let program = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe") { return URL(fileURLWithPath: program).deletingLastPathComponent() }
        return URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        #endif
    }()

    static var caches: URL? {
        #if os(Windows)
        return ProcessInfo.processInfo.environment["LOCALAPPDATA"].map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("app.sole.desktop").appendingPathComponent("Caches") }
        #else
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("Con")
        #endif
    }

    static func prepareText() {
        #if os(Windows)
        _ = _putenv_s("PANGOCAIRO_BACKEND", "fc")
        _ = _putenv_s("FONTCONFIG_FILE", folder.appendingPathComponent("fonts").appendingPathComponent("fonts.conf").withUnsafeFileSystemRepresentation { String(cString: $0!) })
        #endif
    }

    static func open(_ address: String) {
        #if os(Windows)
        _ = address.withCString(encodedAs: UTF16.self) { ShellExecuteW(nil, nil, $0, nil, nil, SW_SHOWNORMAL) }
        #else
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xdg-open")
        process.arguments = [address]
        try? process.run()
        #endif
    }

    static func resource(_ name: String) -> URL? {
        let places = [folder.appendingPathComponent(name), folder.appendingPathComponent("../share/con/\(name)"),
                      folder.appendingPathComponent("../../../Resources/\(name)"), folder.appendingPathComponent("../../../\(name)")]
        return places.first { FileManager.default.fileExists(atPath: $0.standardized.path) }?.standardized
    }
}

@MainActor enum Pad {
    static var connected: Bool {
        (0..<SDL_NumJoysticks()).contains { SDL_IsGameController($0) == SDL_TRUE }
    }
}

@MainActor enum SDLKeyboard {
    static func start() {
        SDL_StartTextInput()
        if Steam.gameMode { Program.open("steam://open/keyboard") }
    }
    static func stop() { SDL_StopTextInput() }
}

enum Steam {
    static var gameMode: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["SteamDeck"] == "1" || environment["SteamGamepadUI"] == "1" || environment["SteamTenfoot"] == "1"
    }
}

@MainActor enum Logo {
    static let surface: OpaquePointer? = {
        guard let url = Program.resource(Program.windows ? "con-logo.png" : "Con.png"), let data = try? Data(contentsOf: url) else { return nil }
        return cairoSurface(data, maxPixels: 256)
    }()
}
