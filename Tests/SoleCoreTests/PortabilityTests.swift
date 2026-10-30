import XCTest

final class PortabilityTests: XCTestCase {
    private static let portable = ["SoleCore", "SoleCloud", "SoleEngine", "SoleLogic"]
    private static let always: Set<String> = ["Foundation", "FoundationNetworking", "CConEngine", "CConPlatform"]

    private func sources(_ module: String) throws -> [URL] { try ProjectSources.swiftFiles(in: "Sources/\(module)") }
    private func lines(of file: URL) throws -> [Substring] { try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false) }
    private func imports(of file: URL) throws -> Set<String> {
        var found = Set<String>()
        for line in try lines(of: file) {
            let words = line.split(separator: " ")
            guard let at = words.firstIndex(of: "import"), at <= 1, words.count > at + 1, !line.hasPrefix("//") else { continue }
            found.insert(String(words[at + 1].split(separator: ".")[0]))
        }
        return found
    }

    func testSharedModulesImportNoPlatformModules() throws {
        try XCTSkipUnless(ProjectSources.available, ProjectSources.missing)
        var files = 0
        for module in Self.portable {
            for file in try sources(module) {
                let needs = try imports(of: file).subtracting(Self.always).subtracting(Self.portable)
                XCTAssertEqual(needs, [], "\(module)/\(file.lastPathComponent) imports platform modules \(needs.sorted()); shared code must stay portable")
                files += 1
            }
        }
        XCTAssertGreaterThan(files, 45, "Expected more than 45 shared source files")
    }

    func testFilesUsingHTTPTypesImportFoundationNetworking() throws {
        try XCTSkipUnless(ProjectSources.available, ProjectSources.missing)
        var speaking = 0
        for module in Self.portable {
            for file in try sources(module) {
                let text = try String(contentsOf: file, encoding: .utf8)
                guard ["URLSession", "URLRequest", "HTTPURLResponse", "HTTPCookie"].contains(where: text.contains) else { continue }
                speaking += 1
                XCTAssertTrue(text.contains("#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif"), "\(module)/\(file.lastPathComponent) uses HTTP types and does not import FoundationNetworking")
            }
        }
        XCTAssertGreaterThan(speaking, 8)
    }

    func testAppleOnlyAPIsAreGuardedByCanImportDarwin() throws {
        try XCTSkipUnless(ProjectSources.available, ProjectSources.missing)
        let theirs = ["sin_len", "pthread_set_qos_class_self_np", "QOS_CLASS_", "CFGetTypeID", "CFBooleanGetTypeID", "SecRandomCopyBytes", "kSec", "NSApp", "os_unfair_lock", "mach_absolute_time"]
        var guarded = 0
        for module in Self.portable {
            for file in try sources(module) {
                var depth = 0, apple: [Int] = []
                for line in try lines(of: file) {
                    let code = line.drop(while: { $0 == " " })
                    if code.hasPrefix("#if") {
                        depth += 1
                        if code.hasPrefix("#if canImport(Darwin)") {
                            apple.append(depth)
                        }
                    } else if code.hasPrefix("#else") || code.hasPrefix("#elseif") {
                        if apple.last == depth {
                            apple.removeLast()
                        }
                    } else if code.hasPrefix("#endif") {
                        if apple.last == depth {
                            apple.removeLast()
                        }
                        depth -= 1
                    }
                    guard !code.hasPrefix("//"), let name = theirs.first(where: { code.contains($0) }) else { continue }
                    XCTAssertFalse(apple.isEmpty, "\(module)/\(file.lastPathComponent) uses \(name) outside of #if canImport(Darwin)")
                    guarded += 1
                }
            }
        }
        XCTAssertGreaterThanOrEqual(guarded, 1, "Expected at least one guarded Apple-only call")
    }

    func testTheSharedSwiftCodeOpensNoSocketsOfItsOwn() throws {
        try XCTSkipUnless(ProjectSources.available, ProjectSources.missing)
        let calls = ["socket(", "bind(", "sendto(", "recvfrom(", "getifaddrs", "getsockname", "sockaddr", "inet_pton", "poll(", "import Glibc", "import Musl", "import Android", "import Darwin", "import WinSDK"]
        for module in Self.portable {
            for file in try sources(module) {
                for line in try lines(of: file) {
                    let code = line.drop(while: { $0 == " " })
                    guard !code.hasPrefix("//"), let call = calls.first(where: { code.contains($0) }) else { continue }
                    XCTFail("\(module)/\(file.lastPathComponent) uses \(call): sockets belong to the engine and to the platform code")
                }
            }
        }
    }

    func testNothingOffTheMacWritesWithTheWriteThatStopsTheApp() throws {
        try XCTSkipUnless(ProjectSources.available, ProjectSources.missing)
        for module in Self.portable + ["ConDesktop", "SoleAndroid"] {
            for file in try sources(module) {
                for line in try lines(of: file) {
                    let code = line.drop(while: { $0 == " " })
                    guard !code.hasPrefix("//"), code.contains("FileHandle"), code.contains(".write("), !code.contains("write(contentsOf:") else { continue }
                    XCTFail("\(module)/\(file.lastPathComponent): \(code) — try? write(contentsOf:) instead")
                }
            }
        }
    }

    func testConsOwnCodeIsSwiftAndRust() throws {
        try XCTSkipUnless(ProjectSources.available, ProjectSources.missing)
        let stillC = ["Sources/CSystem/SDL2/shim.h", "Sources/CSystem/Cairo/shim.h"]
        var found: [String] = []
        for folder in ["Sources", "Tests", "Tools", "Platform", "CredentialAgent", "Resources", "Scripts"] {
            guard let files = FileManager.default.enumerator(at: ProjectSources.root.appendingPathComponent(folder), includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in files where ["c", "h", "m", "mm", "cc", "cpp"].contains(file.pathExtension) {
                let path = String(file.standardizedFileURL.path.dropFirst(ProjectSources.root.standardizedFileURL.path.count + 1))
                if !stillC.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { found.append(path) }
            }
        }
        XCTAssertEqual(found, [], "Con's own code must be Swift or Rust (Platform/), not C or Objective-C")
    }

    func testEveryRequestHasItsBodyUnpacked() throws {
        try XCTSkipUnless(ProjectSources.available, ProjectSources.missing)
        var requests = 0
        for module in Self.portable + ["Sole", "SoleMedia", "ConDesktop", "SoleAndroid"] {
            for file in try sources(module) where file.lastPathComponent != "Gzip.swift" {
                let text = try String(contentsOf: file, encoding: .utf8)
                for call in [".data(for:", ".data(from:", ".dataTask(", ".bytes(for:", ".bytes(from:"] {
                    XCTAssertFalse(text.contains(call), "\(module)/\(file.lastPathComponent) uses \(call); use plainData, otherwise Android returns compressed bodies")
                }
                requests += text.components(separatedBy: ".plainData(").count - 1
            }
        }
        XCTAssertGreaterThanOrEqual(requests, 16, "Expected at least 16 plainData requests")
    }

    func testEverySessionOfTheSharedCodeIsMadeToLast() throws {
        try XCTSkipUnless(ProjectSources.available, ProjectSources.missing)
        var made = 0
        for module in Self.portable {
            for file in try sources(module) where file.lastPathComponent != "Sessions.swift" {
                let text = try String(contentsOf: file, encoding: .utf8)
                XCTAssertFalse(text.contains("URLSession(configuration"), "\(module)/\(file.lastPathComponent) creates its own URLSession; use URLSession.lasting, a released session can crash on Android")
                XCTAssertFalse(text.contains("URLSession.shared"), "\(module)/\(file.lastPathComponent) uses URLSession.shared; on Linux and Android it keeps cookies, a lasting session does not")
                made += text.components(separatedBy: ".lasting(").count - 1
            }
        }
        XCTAssertGreaterThanOrEqual(made, 8, "Expected at least 8 lasting sessions")
    }

    func testTheLogicOfTheAppIsInTheSharedModules() throws {
        try XCTSkipUnless(ProjectSources.available, ProjectSources.missing)
        let places = ["SoleCore": ["PresentationClock", "PictureOrderBridge", "PictureCadence", "GenerationRoom", "StreamMenu", "PadKeyboard", "LibraryPresses", "Localization", "Translations/RussianTexts", "VideoStats", "VideoStream", "ColorWheel", "FocusGeometry", "FocusModel", "PictureQueue", "SoundQueue", "HapticsSound"],
                      "SoleEngine": ["DualSenseReport", "DualSenseDriver", "KeyboardLayout", "KeyboardPlay", "Keys", "MouseLook"],
                      "SoleLogic": ["AppModel", "StreamModel", "Library", "Game", "CloudFailure", "CloudStream", "CloudAuthorization", "PSNAuthorization", "StreamStats", "StreamControls", "StreamSession", "Controls", "LibraryScreen", "StreamPanel"]]
        for (module, names) in places {
            for name in names {
                XCTAssertTrue(FileManager.default.fileExists(atPath: ProjectSources.root.appendingPathComponent("Sources/\(module)/\(name).swift").path), "\(name) belongs to \(module)")
            }
        }
        for name in ["CloudAuthorization", "PSNAuthorization", "StreamMenuInput"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: ProjectSources.root.appendingPathComponent("Sources/Sole/\(name).swift").path), "\(name) belongs to the shared modules, not the app")
        }
    }
}
