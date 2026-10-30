import SoleCore

public enum ConVersion {
    public static let number = "0.5.1"
}

public func localizedCity(_ name: String) -> String {
    let parts = name.components(separatedBy: " · ")
    return ([loc(parts[0])] + parts.dropFirst()).joined(separator: " · ")
}
