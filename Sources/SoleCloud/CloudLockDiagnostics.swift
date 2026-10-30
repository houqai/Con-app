import Foundation
import SoleCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum CloudLockDiagnostics {
    static func entry(status: Int, data: Data, headers: [AnyHashable: Any], forced: Bool, attempt: Int, elapsedMs: Int, requestMs: Int) -> [String: Any] {
        var names: [String] = []
        var retryAfter: Int?
        for (key, value) in headers {
            guard let name = (key as? String)?.lowercased(), !name.isEmpty, name.count <= 40,
                  name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { continue }
            names.append(name)
            if name == "retry-after", let seconds = Int("\(value)".trimmingCharacters(in: .whitespaces)), (0...3600).contains(seconds) { retryAfter = seconds }
        }
        var result: [String: Any] = ["status": status, "forced": forced, "attempt": attempt, "elapsedMs": elapsedMs, "requestMs": requestMs,
                                     "headers": names.sorted(), "answer": shape(data)]
        if let retryAfter { result["retryAfter"] = retryAfter }
        return result
    }

    static func shape(_ data: Data) -> [String: Any] {
        var result: [String: Any] = ["bytes": data.count]
        guard !data.isEmpty else { result["format"] = "empty"; return result }
        guard data.count < 2_000_000, let object = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else { result["format"] = "non-json"; return result }
        if let dictionary = object as? [String: Any] {
            result["format"] = "object"; result["fields"] = fields(dictionary, parent: "", nested: true)
        } else if let array = object as? [Any] {
            result["format"] = "array(\(array.count))"
            if let first = array.first as? [String: Any] { result["first"] = fields(first, parent: "", nested: false) }
        } else {
            result["format"] = type(object)
        }
        return result
    }

    private static func fields(_ object: [String: Any], parent: String, nested: Bool) -> [String: Any] {
        var result: [String: Any] = [:]
        var hidden = 0
        for (key, value) in object.sorted(by: { $0.key < $1.key }).prefix(60) {
            guard safeName(key) else { hidden += 1; continue }
            var field: [String: Any] = ["type": type(value)]
            if let kept = keptValue(value, key: key, parent: parent) { field["value"] = kept }
            if nested, let inner = value as? [String: Any] {
                field["fields"] = fields(inner, parent: key, nested: false)
            } else if nested, let array = value as? [Any], let first = array.first as? [String: Any] {
                field["first"] = fields(first, parent: key, nested: false)
            }
            result[key] = field
        }
        if hidden > 0 { result["(other names)"] = ["type": "count", "value": hidden] }
        if object.count > 60 { result["(more fields)"] = ["type": "count", "value": object.count - 60] }
        return result
    }

    static func type(_ value: Any) -> String {
        if boolean(value) { return "boolean" }
        if let text = value as? String { return "string(\(text.count))" }
        if value is NSNumber { return CloudAllocation.integer(value) != nil ? "integer" : "number" }
        if let array = value as? [Any] { return "array(\(array.count))" }
        if value is [String: Any] { return "object" }
        if value is NSNull { return "null" }
        return "other"
    }

    static func keptValue(_ value: Any, key: String, parent: String) -> Any? {
        if boolean(value) { return (value as? NSNumber)?.boolValue ?? (value as? Bool) }
        guard !sensitive(key) || (key.lowercased() == "name" && parent.lowercased().contains("error")) else { return nil }
        if value is NSNumber, let number = CloudAllocation.integer(value), (-9999...9999).contains(number) { return number }
        if let text = value as? String, word(text) { return text }
        return nil
    }

    private static func boolean(_ value: Any) -> Bool {
        if value is Bool, !(value is NSNumber) { return true }
        guard let number = value as? NSNumber else { return false }
        return number === NSNumber(value: true) || number === NSNumber(value: false) || String(cString: number.objCType) == "c"
    }

    static func word(_ text: String) -> Bool {
        if CloudResponseDiagnostics.isServiceCode(text) { return true }
        guard (1...32).contains(text.count), text.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "_") }) else { return false }
        return !text.allSatisfy { $0.isHexDigit }
    }

    static func safeName(_ key: String) -> Bool {
        guard let first = key.first, first.isASCII, first.isLetter, key.count <= 40,
              key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { return false }
        let digits = key.filter(\.isNumber).count
        return digits <= 3 && !(key.count >= 8 && key.allSatisfy(\.isHexDigit))
    }

    private static func sensitive(_ key: String) -> Bool {
        let name = key.lowercased()
        return ["id", "key", "token", "url", "uri", "ip", "host", "secret", "session", "auth", "cookie", "sign", "address", "name",
                "user", "account", "online", "mail", "nonce", "hash", "ticket", "duid", "device", "serial", "code", "location", "path", "link",
                "message", "description", "text", "title", "label", "display", "player", "owner", "game", "product", "entitlement"]
            .contains { name.contains($0) } && !["errorcode", "eventcode", "componentcode", "statuscode", "reasoncode"].contains(name)
    }

    static func write(_ trace: [[String: Any]]) {
        guard let directory = Diagnostics.directory,
              let encoded = try? JSONSerialization.data(withJSONObject: trace, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? encoded.write(to: directory.appendingPathComponent("cloud-lock.json"), options: .atomic)
    }
}
