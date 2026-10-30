import Foundation
import Security
import SoleCloud
import SoleCore
import SoleLogic

struct KeychainCredentials: CredentialStore {
    private static let queue = DispatchQueue(label: "app.sole.credentials", qos: .userInitiated)
    private static let migrated = "sole.credentialAgentMigrated"
    private static var unavailable: CredentialStoreFailure { CredentialStoreFailure(loc("Could not access the macOS Keychain.")) }

    func read(_ account: String) async throws -> Data? {
        if let data = try await agent("read", account: account) {
            markMigrated(account)
            return data
        }
        guard account == PSNAuthorization.refreshAccount, !UserDefaults.standard.bool(forKey: Self.migrated) else { return nil }
        for service in ["app.sole.psn.v3", "app.sole.psn.v2", "app.sole.psn"] {
            if let token = try? await readItem(Self.query(service: service, account: PSNAuthorization.refreshAccount)) {
                try await write(Data(token.utf8), account: PSNAuthorization.refreshAccount)
                if let encoded = try? await readItem(Self.query(service: service, account: PSNAuthorization.ssoAccount)),
                   let sso = try? JSONDecoder().decode(SonySSO.self, from: Data(encoded.utf8)), sso.isValid {
                    try await write(try JSONEncoder().encode(sso), account: PSNAuthorization.ssoAccount)
                }
                return Data(token.utf8)
            }
        }
        return nil
    }
    func write(_ data: Data, account: String) async throws {
        _ = try await agent("write", account: account, data: data)
        markMigrated(account)
    }
    func remove(_ account: String) async throws {
        _ = try await agent("remove", account: account)
        markMigrated(account)
    }

    private func markMigrated(_ account: String) {
        if account == PSNAuthorization.refreshAccount { UserDefaults.standard.set(true, forKey: Self.migrated) }
    }

    private func agent(_ operation: String, account: String, data: Data? = nil) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                continuation.resume(with: Result {
                    do { return try CredentialAgent.perform(operation, account: account, data: data) }
                    catch { throw Self.unavailable }
                })
            }
        }
    }
    private static func query(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
    }
    private func readItem(_ query: [String: Any]) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                continuation.resume(with: Result { try Self.performRead(query) })
            }
        }
    }
    private static func performRead(_ query: [String: Any]) throws -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw unavailable }
        return String(data: data, encoding: .utf8)
    }
}
