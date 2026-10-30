import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct SonySSO: Codable, Sendable {
    public let value: String
    public let expiresAt: Date
    public var isValid: Bool { expiresAt > Date() && Self.validValue(value) }
    private static let fallbackLifetime: TimeInterval = 86400
    public static func validValue(_ value: String) -> Bool {
        !value.isEmpty && value.count < 16384 && value.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || "_-.".contains($0))
        }
    }
    public static func credential(from cookies: [HTTPCookie], now: Date = Date()) -> SonySSO? {
        let allowed = ["sony.com", "account.sony.com", "ca.account.sony.com", "my.account.sony.com"]
        let matches = cookies.filter {
            let domain = $0.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return $0.name == "npsso" && $0.isSecure && allowed.contains(domain) &&
                Self.validValue($0.value) && ($0.expiresDate ?? now.addingTimeInterval(fallbackLifetime)) > now
        }
        guard Set(matches.map(\.value)).count == 1, let cookie = matches.first else { return nil }
        return SonySSO(value: cookie.value, expiresAt: matches.compactMap(\.expiresDate).min() ?? now.addingTimeInterval(fallbackLifetime))
    }

    public static func credential(sentSecurely: String, sentPlainly: String, now: Date = Date()) -> SonySSO? {
        func values(_ header: String) -> [String] {
            header.split(separator: ";").compactMap { pair -> String? in
                let parts = pair.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                return parts.count == 2 && parts[0] == "npsso" ? String(parts[1]) : nil
            }
        }
        let secure = values(sentSecurely)
        guard values(sentPlainly).isEmpty, Set(secure).count == 1, let value = secure.first, validValue(value) else { return nil }
        return SonySSO(value: value, expiresAt: now.addingTimeInterval(fallbackLifetime))
    }
}
