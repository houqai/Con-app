import Foundation
import Security
import Darwin

// The immutable helper owns the file-keychain items. Only a correctly signed
// Sole parent may use its private stdin/stdout channel. It never logs secrets.
struct Request: Codable { let operation: String; let account: String; let data: Data? }
struct Reply: Codable { let status: Int32; let data: Data? }
func reply(_ status: OSStatus, _ data: Data? = nil) -> Never {
    if let encoded = try? JSONEncoder().encode(Reply(status: status, data: data)) {
        FileHandle.standardOutput.write(encoded)
    }
    exit(status == errSecSuccess || status == errSecItemNotFound ? 0 : 1)
}
SecKeychainSetUserInteractionAllowed(false)
var parent: SecCode?
let parentStatus = SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: getppid()] as CFDictionary, [], &parent)
var requirement: SecRequirement?
let text = "identifier \"app.sole.desktop\" and certificate leaf = H\"50569e7fb68ed1ddc0b733eb2ecb3e77487d17bd\""
guard parentStatus == errSecSuccess, let parent,
      SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement,
      SecCodeCheckValidity(parent, [], requirement) == errSecSuccess else { reply(errSecAuthFailed) }
let encoded = FileHandle.standardInput.readDataToEndOfFile()
guard encoded.count < 1_500_000, let request = try? JSONDecoder().decode(Request.self, from: encoded),
      ["refresh", "cloud-sso", "consoles", "probe"].contains(request.account) else { reply(errSecParam) }
let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "app.sole.credentials.agent.v1", kSecAttrAccount as String: request.account,
    kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
switch request.operation {
case "read":
    var lookup = query; lookup[kSecReturnData as String] = true; lookup[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(lookup as CFDictionary, &result)
    reply(status, status == errSecSuccess ? result as? Data : nil)
case "write":
    guard let data = request.data, data.count < 1_000_000 else { reply(errSecParam) }
    let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecSuccess { reply(status) }
    guard status == errSecItemNotFound else { reply(status) }
    var item = query; item[kSecValueData as String] = data
    item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    reply(SecItemAdd(item as CFDictionary, nil))
case "remove": reply(SecItemDelete(query as CFDictionary))
default: reply(errSecParam)
}
