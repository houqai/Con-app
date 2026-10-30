import Foundation
import Security
import SoleEngine
import SoleLogic

enum ConsoleStore {
    private static let service = "app.sole.consoles.v1"
    private static let account = "registered"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
    }

    static func load() -> [RegisteredConsole] {
        if let data = try? CredentialAgent.perform("read", account: "consoles"),
           let consoles = try? JSONDecoder().decode([RegisteredConsole].self, from: data) { return consoles }
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let consoles = try? JSONDecoder().decode([RegisteredConsole].self, from: data) else { return [] }
        _ = try? CredentialAgent.perform("write", account: "consoles", data: data)
        return consoles
    }

    static func save(_ consoles: [RegisteredConsole]) -> Bool {
        guard let data = try? JSONEncoder().encode(consoles) else { return false }
        do { _ = try CredentialAgent.perform("write", account: "consoles", data: data); return true }
        catch { return false }
    }
}
