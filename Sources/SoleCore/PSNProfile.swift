import Foundation

public struct PSNProfile: Sendable, Equatable {
    public let onlineID: String
    public let avatarURL: URL?
    public let isPlus: Bool?

    public static func decode(_ data: Data) -> PSNProfile? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = object["onlineId"] as? String, !name.isEmpty else { return nil }
        var bySize: [String: URL] = [:]
        var listed: [URL] = []
        for avatar in (object["avatars"] as? [[String: Any]]) ?? [] {
            guard let value = avatar["url"] as? String, let url = avatarURL(value) else { continue }
            listed.append(url)
            if let size = avatar["size"] as? String, bySize[size] == nil { bySize[size] = url }
        }
        let avatar = ["xl", "l", "m", "s"].compactMap { bySize[$0] }.first ?? listed.first
        return PSNProfile(onlineID: name, avatarURL: avatar, isPlus: object["isPlus"] as? Bool)
    }

    static func avatarURL(_ value: String) -> URL? {
        guard var parts = URLComponents(string: value), let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil else { return nil }
        if parts.scheme == "http", parts.port == nil, host.hasSuffix(".playstation.net") || host.hasSuffix(".playstation.com") {
            parts.scheme = "https"
        }
        guard parts.scheme == "https" else { return nil }
        return parts.url
    }
}
