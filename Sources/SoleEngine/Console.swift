public enum ConsoleTarget: UInt32, Sendable, CaseIterable {
    case ps4Unknown = 0
    case ps4v8 = 800
    case ps4v9 = 900
    case ps4v10 = 1000
    case ps5Unknown = 1_000_000
    case ps5v1 = 1_000_100

    public static func isPS5(_ value: UInt32) -> Bool { value >= ConsoleTarget.ps5Unknown.rawValue }
}

public struct DiscoveredConsole: Identifiable, Sendable, Hashable {
    public enum State: Sendable { case unknown, ready, standby }
    public let hostID: String
    public let name: String
    public let address: String
    public let isPS5: Bool
    public let state: State
    public let systemVersion: String?
    public let targetValue: UInt32

    public var id: String { hostID.isEmpty ? address : hostID }

    public init(hostID: String, name: String, address: String, isPS5: Bool, state: State = .unknown, systemVersion: String? = nil, targetValue: UInt32) {
        self.hostID = hostID; self.name = name; self.address = address; self.isPS5 = isPS5
        self.state = state; self.systemVersion = systemVersion; self.targetValue = targetValue
    }
}
