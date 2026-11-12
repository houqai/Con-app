import Foundation

public enum PSNIdentity {
    private enum Claim: Decodable {
        case text(String), number(UInt64), other
        init(from decoder: Decoder) throws {
            guard let value = try? decoder.singleValueContainer() else { self = .other; return }
            if let text = try? value.decode(String.self) { self = .text(text) }
            else if let number = try? value.decode(UInt64.self) { self = .number(number) }
            else { self = .other }
        }
        var accountID: String? {
            switch self {
            case .text(let text): return normalizedAccountID(text)
            case .number(let number): return normalizedAccountID(String(number))
            case .other: return nil
            }
        }
    }
    private static func accountID(in object: Data, keys: [String]) -> String? {
        guard let claims = try? JSONDecoder().decode([String: Claim].self, from: object) else { return nil }
        return keys.lazy.compactMap { claims[$0]?.accountID }.first
    }

    public static func accountID(fromJWT token: String) -> String? {
        payload(token).flatMap { accountID(in: $0, keys: ["user_id", "account_id", "uid", "sub"]) }
    }
    public static func accountID(fromTokenInfo data: Data) -> String? { accountID(in: data, keys: ["user_id"]) }
    private static let countryKeys = ["country_code", "legal_country", "country"]
    private static func country(in object: Data) -> String? {
        guard let claims = try? JSONDecoder().decode([String: Claim].self, from: object) else { return nil }
        return countryKeys.lazy.compactMap { key -> String? in
            guard case .text(let value)? = claims[key] else { return nil }
            return normalizedCountry(value)
        }.first
    }
    public static func country(fromJWT token: String) -> String? {
        payload(token).flatMap(country(in:))
    }
    public static func country(fromTokenInfo data: Data) -> String? { country(in: data) }
    public static func normalizedCountry(_ value: String) -> String? {
        guard value.count == 2, value.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return value.uppercased()
    }
    private static func payload(_ token: String) -> Data? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { return nil }
        var payload = String(segments[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        return Data(base64Encoded: payload)
    }
    public static func normalizedAccountID(_ value: String) -> String? {
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = UInt64(value), number != 0 else { return nil }
        return String(number)
    }

    public static func accountIDBytes(_ decimal: String) -> [UInt8]? {
        guard let normalized = normalizedAccountID(decimal), let number = UInt64(normalized) else { return nil }
        return withUnsafeBytes(of: number.bigEndian) { Array($0) }
    }
}
