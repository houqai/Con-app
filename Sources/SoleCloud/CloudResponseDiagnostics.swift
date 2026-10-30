import Foundation
import SoleCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum CloudResponseDiagnostics {
    private static let categoryWords = ["entitlement", "latency", "bandwidth", "subscription", "premium", "scope", "unauthorized", "forbidden", "resolution", "invalid",
                                        "denied", "capacity", "rtt", "session", "token", "state", "config", "client", "network", "key", "auth", "ping", "data center",
                                        "datacenter", "requirement", "region", "country", "missing", "required", "unsupported", "available", "quality", "threshold",
                                        "body", "field", "format"]
    static func isServiceCode(_ value: String) -> Bool {
        let groups = value.split(separator: ".", omittingEmptySubsequences: false)
        return groups.count == 2 && groups[0].count == 3 && groups[1].count == 4 && groups.allSatisfy { $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }
    static func numericCode(_ value: String) -> Bool {
        let digits = value.hasPrefix("-") ? value.dropFirst() : Substring(value)
        let serviceCode = isServiceCode(value)
        let decimal = !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
        let hexadecimal = (value.count == 8 && value.allSatisfy { $0.isASCII && $0.isHexDigit }) || (value.count == 10 && value.hasPrefix("0x") && value.dropFirst(2).allSatisfy { $0.isASCII && $0.isHexDigit })
        return serviceCode || decimal || hexadecimal
    }
    static func record(status: Int, data: Data, response: HTTPURLResponse) {
        guard let encoded = summary(status: status, data: data, response: response),
              let directory = Diagnostics.directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? encoded.write(to: directory.appendingPathComponent("cloud-response.json"), options: [.atomic])
    }

    static func summary(status: Int, data: Data, response: HTTPURLResponse) -> Data? {
        guard data.count < 2_000_000 else { return nil }
        let object = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        var result: [String: Any] = ["status": status, "bytes": data.count,
            "format": object is [String: Any] ? "object" : object is [Any] ? "array" : object is String ? "json-string" : "non-json"]
        let known = Set(["error", "errors", "errorCode", "error_code", "code", "name", "message", "description", "error_description", "httpCode", "componentCode", "eventCode", "reason", "status", "statusCode", "status_code", "type"])
        var types: [String: String] = [:]
        var fields: [String] = []
        var codes: [String: String] = [:]
        var categories = Set<String>()
        func visit(_ value: Any, path: String, depth: Int) {
            guard depth < 5 else { return }
            if let dictionary = value as? [String: Any] {
                for (key, child) in dictionary where known.contains(key) {
                    let childPath = path.isEmpty ? key : path + "." + key
                    fields.append(childPath)
                    types[childPath] = (child as? String).map { "string(\($0.count))" } ?? (child is NSNumber ? "number" : child is NSNull ? "null" : child is [Any] ? "array" : "object")
                    if ["errorCode", "error_code", "code", "componentCode", "eventCode", "statusCode", "status_code"].contains(key),
                       let number = (child as? String) ?? (child as? NSNumber)?.stringValue,
                       !number.isEmpty, number.count <= 10, numericCode(number) { codes[childPath] = number }
                    visit(child, path: childPath, depth: depth + 1)
                }
            } else if let array = value as? [Any] {
                for child in array.prefix(5) { visit(child, path: path + "[]", depth: depth + 1) }
            } else if let text = value as? String {
                for category in categoryWords where text.lowercased().contains(category) { categories.insert(category) }
            }
        }
        if let object { visit(object, path: "", depth: 0) }
        result["fields"] = Array(Set(fields)).sorted(); result["codes"] = codes
        result["categories"] = categories.sorted(); result["types"] = types
        result["cloudfront"] = response.value(forHTTPHeaderField: "Server")?.lowercased() == "cloudfront"
        return try? JSONSerialization.data(withJSONObject: result, options: .sortedKeys)
    }
}
