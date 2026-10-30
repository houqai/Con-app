import XCTest
@testable import SoleCore

final class LocalizationTests: XCTestCase {
    func testEnglishIsShownUntilALanguageIsChosen() {
        XCTAssertNil(Settings.store.string(forKey: AppLanguage.storageKey))
        XCTAssertEqual(AppLanguage.current, .english)
    }

    func testATextIsItselfInEnglishAndTranslatedInRussian() {
        XCTAssertEqual(Localization.text("Settings", in: .english), "Settings")
        XCTAssertEqual(Localization.text("Settings", in: .russian), "Настройки")
        XCTAssertEqual(Localization.text("Cyberpunk 2077", in: .russian), "Cyberpunk 2077")
        XCTAssertEqual(Localization.text("Unknown text", in: .russian), "Unknown text")
    }

    func testValuesFillPlaceholdersInOrder() {
        XCTAssertEqual(Localization.text("Server: %@%@.", values: ["Tokyo, Japan", ", 104 ms"], in: .english), "Server: Tokyo, Japan, 104 ms.")
        XCTAssertEqual(Localization.text("%@ games", values: [122], in: .russian), "122 игр")
        XCTAssertEqual(Localization.text("%@ games", values: [122], in: .english), "122 games")
        XCTAssertEqual(Localization.text("Session ended: %@", values: ["100%@ %@"], in: .english), "Session ended: 100%@ %@")
        XCTAssertEqual(Localization.text("Registering %@…", values: [], in: .english), "Registering %@…")
    }

    private var translated: [AppLanguage] { AppLanguage.allCases.filter { $0 != .english } }
    private var keys: Set<String> { Set(Translations.russian.keys) }

    func testEveryKeyIsEnglish() {
        for key in keys {
            XCTAssertFalse(key.isEmpty)
            XCTAssertFalse(key.unicodeScalars.contains { (0x400...0x4ff).contains($0.value) }, key)
        }
    }

    func testEveryLanguageHasEveryTextAndNoOther() {
        XCTAssertEqual(translated.count, 10)
        XCTAssertGreaterThan(keys.count, 400)
        for language in translated {
            let table = language.table ?? [:]
            XCTAssertEqual(Set(table.keys).subtracting(keys), [], "\(language.name) has texts the Russian table does not")
            XCTAssertEqual(keys.subtracting(table.keys), [], "\(language.name) lacks texts")
        }
    }

    func testEveryTranslationKeepsPlaceholdersLineBreaksAndEdgeSpaces() {
        for language in translated {
            for (english, text) in language.table ?? [:] {
                XCTAssertEqual(text.components(separatedBy: "%@").count, english.components(separatedBy: "%@").count, "\(language.name): \(english)")
                XCTAssertEqual(text.components(separatedBy: "\n").count, english.components(separatedBy: "\n").count, "\(language.name): \(english)")
                XCTAssertFalse(text.trimmingCharacters(in: .whitespaces).isEmpty, "\(language.name): \(english)")
                if language != .russian {
                    XCTAssertFalse(text.unicodeScalars.contains { (0x400...0x4ff).contains($0.value) }, "\(language.name) has Russian letters in: \(text)")
                }
                XCTAssertEqual(text.hasPrefix(" "), english.hasPrefix(" "), "\(language.name): \"\(text)\"")
                XCTAssertEqual(text.hasSuffix(" "), english.hasSuffix(" "), "\(language.name): \"\(text)\"")
            }
        }
    }

    func testATranslationIsATranslation() {
        for language in translated {
            let table = language.table ?? [:]
            let same = table.filter { $0.key == $0.value }.count
            XCTAssertLessThan(same, table.count / 6, "\(language.name): \(same) of \(table.count) texts are the English ones")
        }
        XCTAssertEqual(Localization.text("Settings", in: .german), "Einstellungen")
        XCTAssertEqual(Localization.text("Settings", in: .french), "Réglages")
        XCTAssertEqual(Localization.text("Settings", in: .spanish), "Ajustes")
        XCTAssertEqual(Localization.text("Settings", in: .italian), "Impostazioni")
        XCTAssertEqual(Localization.text("Settings", in: .polish), "Ustawienia")
        XCTAssertEqual(Localization.text("Settings", in: .portuguese), "Ajustes")
        XCTAssertEqual(Localization.text("Settings", in: .japanese), "設定")
        XCTAssertEqual(Localization.text("Settings", in: .korean), "설정")
        XCTAssertEqual(Localization.text("Settings", in: .chinese), "设置")
        XCTAssertEqual(Localization.text("%@ games", values: [122], in: .german), "122 Spiele")
        XCTAssertEqual(Localization.text("Server: %@%@.", values: ["Tokio, Japan", ", 104 ms"], in: .german), "Server: Tokio, Japan, 104 ms.")
        XCTAssertEqual(Localization.text("Cyberpunk 2077", in: .japanese), "Cyberpunk 2077")
        XCTAssertEqual(Localization.text("Unknown text", in: .korean), "Unknown text")
    }

    func testCityNamesKeepTheCommaBeforeTheCountry() {
        for language in AppLanguage.allCases {
            XCTAssertTrue(Localization.text("Tokyo, Japan", in: language).contains(", "), language.name)
            XCTAssertTrue(Localization.text("Frankfurt, Germany", in: language).contains(", "), language.name)
        }
    }

    func testLanguagesAreDistinctAndMatchTheGameLanguages() {
        XCTAssertEqual(Set(AppLanguage.allCases.map(\.rawValue)).count, AppLanguage.allCases.count)
        XCTAssertEqual(Set(AppLanguage.allCases.map(\.name)).count, AppLanguage.allCases.count)
        XCTAssertEqual(AppLanguage(rawValue: "de"), .german)
        XCTAssertEqual(AppLanguage(rawValue: "zh"), .chinese)
        XCTAssertEqual(Set(GameLanguage.all.map(\.code)), Set(AppLanguage.allCases.map(\.rawValue)))
        XCTAssertEqual(Set(GameLanguage.all.map(\.code)).count, GameLanguage.all.count)
        XCTAssertTrue(GameLanguage.isKnown(GameLanguage.standard))
        XCTAssertFalse(GameLanguage.isKnown("xx"))
        XCTAssertFalse(GameLanguage.isKnown(""))
    }

    private static let literal = try! NSRegularExpression(pattern: #""(?:[^"\\\n]|\\.)*""#)
    private static let shown = try! NSRegularExpression(pattern: #"(?:\bloc\(|\bcase \w+ = )"((?:[^"\\\n]|\\.)*)""#)

    private static func value(of source: String) -> String {
        var text = source
        for (escape, character) in [("\\n", "\n"), ("\\\"", "\""), ("\\t", "\t"), ("\\\\", "\\")] {
            text = text.replacingOccurrences(of: escape, with: character)
        }
        return text
    }

    private func matches(_ expression: NSRegularExpression, in line: String) -> [String] {
        expression.matches(in: line, range: NSRange(line.startIndex..., in: line)).map {
            let range = Range($0.range(at: $0.numberOfRanges > 1 ? 1 : 0), in: line)!
            return String(line[range])
        }
    }

    func testEveryTextOfTheInterfaceHasItsTranslations() throws {
        try XCTSkipUnless(ProjectSources.available, ProjectSources.missing)
        let files = try ProjectSources.swiftFiles(in: "Sources/Sole") + ProjectSources.swiftFiles(in: "Sources/SoleLogic") + ProjectSources.swiftFiles(in: "Sources/SoleAndroid") + ProjectSources.swiftFiles(in: "Sources/ConDesktop")
        XCTAssertGreaterThan(files.count, 25)
        var checked = 0
        for file in files {
            for line in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n") {
                for source in matches(Self.shown, in: line) {
                    let text = Self.value(of: source)
                    guard line.contains("loc(") || line.range(of: #"enum (SettingsSection|Destination|LibraryFilter)\b"#, options: .regularExpression) != nil
                        || line.contains("case general = ") else { continue }
                    XCTAssertTrue(keys.contains(text), "\(file.lastPathComponent): \"\(text)\" has no translations")
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 300)
    }

    func testNoRussianIsLeftInTheSourcesOutsideTheRussianTable() throws {
        try XCTSkipUnless(ProjectSources.available, ProjectSources.missing)
        let directories = ["Sources/Sole", "Sources/SoleLogic", "Sources/SoleAndroid", "Sources/ConDesktop", "Sources/SoleCloud", "Sources/SoleEngine", "Sources/SoleCore", "Sources/SoleMedia"]
        let allowed: Set<String> = ["Русский", "а"]
        for directory in directories {
            for file in try ProjectSources.swiftFiles(in: directory) {
                for line in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n") {
                    for source in matches(Self.literal, in: line) where source.unicodeScalars.contains(where: { (0x400...0x4ff).contains($0.value) }) {
                        XCTAssertTrue(allowed.contains(String(source.dropFirst().dropLast())), "\(file.lastPathComponent): \(source)")
                    }
                }
            }
        }
    }

    func testEveryTextStandsInTheRussianTableOnce() throws {
        try XCTSkipUnless(ProjectSources.available, ProjectSources.missing)
        let source = try String(contentsOf: ProjectSources.root.appendingPathComponent("Sources/SoleCore/Translations/RussianTexts.swift"), encoding: .utf8)
        var seen = Set<String>(), entries = 0
        for line in source.split(separator: "\n") {
            let text = line.drop(while: { $0 == " " })
            guard text.hasPrefix("\""), let end = text.dropFirst().range(of: "\": \"") else { continue }
            let key = String(text.dropFirst()[..<end.lowerBound])
            entries += 1
            XCTAssertTrue(seen.insert(key).inserted, "\"\(key)\" is in the table twice")
        }
        XCTAssertEqual(entries, Translations.russian.count, "Every line of the table was read")
    }

    func testTextsThatComeFromTheOtherModulesHaveTheirTranslations() throws {
        try XCTSkipUnless(ProjectSources.available, ProjectSources.missing)
        let files = ["Sources/SoleCloud/CloudSession.swift", "Sources/SoleCloud/CloudEntitlement.swift", "Sources/SoleCloud/CloudDatacenterName.swift",
                     "Sources/SoleEngine/RustEngine.swift"]
        var checked = 0
        for path in files {
            for line in try String(contentsOf: ProjectSources.root.appendingPathComponent(path), encoding: .utf8).components(separatedBy: "\n") {
                for source in matches(Self.literal, in: line) where keys.contains(Self.value(of: String(source.dropFirst().dropLast()))) { checked += 1 }
            }
        }
        XCTAssertGreaterThan(checked, 45)
    }
}
