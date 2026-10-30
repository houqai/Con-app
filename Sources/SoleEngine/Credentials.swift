public struct RemotePlayCredentials: Sendable, Codable, Hashable {
    public var registKey: [UInt8]
    public var morning: [UInt8]
    public var targetValue: UInt32
    public var serverMAC: [UInt8]
    public var consolePIN: UInt32

    public var isPS5: Bool { ConsoleTarget.isPS5(targetValue) }

    public init(registKey: [UInt8], morning: [UInt8], targetValue: UInt32, serverMAC: [UInt8], consolePIN: UInt32) {
        self.registKey = registKey
        self.morning = morning
        self.targetValue = targetValue
        self.serverMAC = serverMAC
        self.consolePIN = consolePIN
    }

    var valid: Bool { registKey.count == 16 && morning.count == 16 }
}
