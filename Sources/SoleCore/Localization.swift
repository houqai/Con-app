import Foundation

public enum AppLanguage: String, CaseIterable, Sendable {
    case english = "en", russian = "ru", german = "de", spanish = "es", french = "fr", italian = "it", polish = "pl", portuguese = "pt"
    case japanese = "ja", korean = "ko", chinese = "zh"
    public static let storageKey = "sole.language"
    public static var current: AppLanguage {
        AppLanguage(rawValue: Settings.store.string(forKey: storageKey) ?? "") ?? .english
    }
    public var name: String {
        switch self {
        case .english: return "English"
        case .russian: return "Russian"
        case .german: return "Deutsch"
        case .spanish: return "Español"
        case .french: return "Français"
        case .italian: return "Italiano"
        case .polish: return "Polski"
        case .portuguese: return "Português (Brasil)"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .chinese: return "简体中文"
        }
    }
    var table: [String: String]? {
        switch self {
        case .english: return nil
        case .russian: return Translations.russian
        case .german: return Translations.german
        case .spanish: return Translations.spanish
        case .french: return Translations.french
        case .italian: return Translations.italian
        case .polish: return Translations.polish
        case .portuguese: return Translations.portuguese
        case .japanese: return Translations.japanese
        case .korean: return Translations.korean
        case .chinese: return Translations.chinese
        }
    }
}

public enum Translations {}

public enum GameLanguage {
    public static let standard = "en"
    public static let all: [(code: String, name: String)] = [
        ("en", "English"), ("ru", "Russian"), ("de", "Deutsch"), ("es", "Español"), ("fr", "Français"), ("it", "Italiano"),
        ("pl", "Polski"), ("pt", "Português"), ("ja", "日本語"), ("ko", "한국어"), ("zh", "中文"),
    ]
    public static func isKnown(_ code: String) -> Bool { all.contains { $0.code == code } }
}

public func loc(_ english: String) -> String { Localization.text(english) }
public func loc(_ english: String, _ values: Any...) -> String { Localization.text(english, values: values) }

public enum Localization {
    public static func text(_ english: String, in language: AppLanguage = .current) -> String {
        language.table?[english] ?? english
    }
    public static func text(_ english: String, values: [Any], in language: AppLanguage = .current) -> String {
        var result = text(english, in: language)
        var from = result.startIndex
        for value in values {
            guard let place = result.range(of: "%@", range: from..<result.endIndex) else { break }
            let written = String(describing: value)
            result.replaceSubrange(place, with: written)
            from = result.index(place.lowerBound, offsetBy: written.count)
        }
        return result
    }
}
