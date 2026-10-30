// swift-tools-version: 6.0
import PackageDescription
import Foundation

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

enum System: String { case macOS = "macos", android, linux, windows }
let system = ProcessInfo.processInfo.environment["CON_SYSTEM"].flatMap { System(rawValue: $0.lowercased()) } ?? .macOS

let rustSystem: Platform = {
    switch system {
    case .android: return .android
    case .linux: return .linux
    case .windows: return .windows
    case .macOS: return .macOS
    }
}()
let rustTarget: String = {
    switch system {
    case .android: return "aarch64-linux-android"
    case .linux:
        #if arch(x86_64)
        return "x86_64-unknown-linux-gnu"
        #else
        return "aarch64-unknown-linux-gnu"
        #endif
    case .windows: return "x86_64-pc-windows-msvc"
    case .macOS: return "aarch64-apple-darwin"
    }
}()
func rustFolder(_ variable: String, _ work: String) -> String {
    ProcessInfo.processInfo.environment[variable].flatMap { $0.isEmpty ? nil : $0 } ?? "\(packageRoot)/work/\(work)/\(rustTarget)"
}
func systemLibraries(_ folder: String, _ file: String = "native-libs.txt") -> [String] {
    guard let text = try? String(contentsOfFile: "\(folder)/\(file)", encoding: .utf8) else { return [] }
    var seen: Set<String> = []
    var flags: [String] = []
    let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" }).map(String.init)
    var index = 0
    while index < words.count {
        let word = words[index]
        index += 1
        if word == "-framework", index < words.count {
            if seen.insert("-framework " + words[index]).inserted { flags += [word, words[index]] }
            index += 1
            continue
        }
        let flag = word.hasSuffix(".lib") ? "-l" + word.dropLast(4) : word.hasPrefix("-l") || word.hasPrefix("-L") ? word : nil
        if let flag, seen.insert(flag).inserted { flags.append(flag) }
    }
    return flags
}
func rustLibrary(_ folder: String, _ name: String) -> String {
    "\(folder)/\(system == .windows ? "\(name).lib" : "lib\(name).a")"
}
let engineFolder = rustFolder("CON_ENGINE_LIB", "engine-rust")
let engineLinkerSettings: [LinkerSetting] = [.unsafeFlags([rustLibrary(engineFolder, "con_engine")] + systemLibraries(engineFolder), .when(platforms: [rustSystem]))]
let platformFolder = rustFolder("CON_PLATFORM_LIB", "platform-rust")
let platformLinkerSettings: [LinkerSetting] = [
    .unsafeFlags([rustLibrary(platformFolder, "con_platform")] + systemLibraries(platformFolder), .when(platforms: [rustSystem])),
    .unsafeFlags(["-Xlinker", "/include:con_wine_heap_start"], .when(platforms: [.windows])),
]
let desktopLinkerSettings: [LinkerSetting] = [
    .unsafeFlags([rustLibrary(platformFolder, "con_desktop")] + systemLibraries(platformFolder, "native-libs-desktop.txt"), .when(platforms: [rustSystem])),
]
let androidLinkerSettings: [LinkerSetting] = [
    .unsafeFlags([rustLibrary(platformFolder, "con_android")] + systemLibraries(platformFolder, "native-libs-android.txt"), .when(platforms: [rustSystem])),
]
let androidCheckLinkerSettings: [LinkerSetting] = [
    .unsafeFlags([rustLibrary(platformFolder, "con_android_check")] + systemLibraries(platformFolder, "native-libs-android-check.txt"), .when(platforms: [rustSystem])),
]

let sharedTargets: [Target] = [
    .systemLibrary(name: "CConEngine", path: "Sources/CConEngine"),
    .systemLibrary(name: "CConPlatform", path: "Sources/CConPlatform"),
    .target(name: "SoleCore", linkerSettings: platformLinkerSettings),
    .target(name: "SoleCloud", dependencies: ["SoleCore"]),
    .target(name: "SoleEngine", dependencies: ["CConEngine", "CConPlatform"], linkerSettings: engineLinkerSettings + platformLinkerSettings),
    .target(name: "SoleLogic", dependencies: ["SoleCore", "SoleCloud", "SoleEngine"]),
    .testTarget(name: "SoleCoreTests", dependencies: ["SoleCore", "CConPlatform"]),
    .testTarget(name: "SoleCloudTests", dependencies: ["SoleCloud"]),
    .testTarget(name: "SoleEngineTests", dependencies: ["SoleEngine", "CConPlatform"]),
    .testTarget(name: "SoleLogicTests", dependencies: ["SoleLogic"]),
]
let macTargets: [Target] = [
    .target(name: "SoleMedia", dependencies: ["SoleCore", "CConPlatform"]),
    .executableTarget(name: "Sole", dependencies: ["SoleCore", "SoleCloud", "SoleMedia", "SoleEngine", "SoleLogic"]),
    .testTarget(name: "SoleTests", dependencies: ["Sole"]),
    .testTarget(name: "SoleMediaTests", dependencies: ["SoleMedia"]),
]

let androidTargets: [Target] = [
    .systemLibrary(name: "CConAndroid", path: "Sources/CConAndroid"),
    .systemLibrary(name: "CConAndroidCheck", path: "Sources/CConAndroidCheck"),
    .target(name: "SoleAndroid", dependencies: ["SoleCore", "SoleCloud", "SoleEngine", "SoleLogic", "CConAndroid"], linkerSettings: androidLinkerSettings),
    .executableTarget(name: "ConAndroidCheck", dependencies: ["SoleCore", "SoleEngine", "SoleLogic", "SoleAndroid", "CConAndroid", "CConAndroidCheck"], path: "Tools/AndroidCheck",
                      linkerSettings: androidCheckLinkerSettings),
]

let desktopTargets: [Target] = [
    .systemLibrary(name: "CSDL2", path: "Sources/CSystem/SDL2", pkgConfig: "sdl2"),
    .systemLibrary(name: "CCairo", path: "Sources/CSystem/Cairo", pkgConfig: "pangocairo"),
    .systemLibrary(name: "CConDesktop", path: "Sources/CConDesktop"),
    .executableTarget(name: "ConDesktop", dependencies: ["SoleCore", "SoleCloud", "SoleEngine", "SoleLogic", "CConDesktop", "CSDL2", "CCairo"],
                      linkerSettings: desktopLinkerSettings + [.linkedLibrary("shell32", .when(platforms: [.windows]))]),
]

let systemProducts: [Product] = {
    switch system {
    case .android:
        return [.library(name: "SoleCloud", targets: ["SoleCloud"]), .executable(name: "ConAndroidCheck", targets: ["ConAndroidCheck"]),
                .library(name: "ConShared", type: .dynamic, targets: ["SoleLogic", "SoleAndroid"])]
    case .linux: return [.library(name: "SoleCloud", targets: ["SoleCloud"]), .executable(name: "con", targets: ["ConDesktop"])]
    case .windows: return [.library(name: "SoleCloud", targets: ["SoleCloud"]), .executable(name: "con-app", targets: ["ConDesktop"])]
    case .macOS: return [.executable(name: "Con", targets: ["Sole"]), .library(name: "SoleCloud", targets: ["SoleCloud"])]
    }
}()

let systemTargets: [Target] = {
    switch system {
    case .android: return androidTargets
    case .linux, .windows: return desktopTargets
    case .macOS: return macTargets
    }
}()

let package = Package(
    name: "Con",
    platforms: [.macOS(.v14)],
    products: systemProducts,
    targets: sharedTargets + systemTargets,
    swiftLanguageModes: [.v5]
)
