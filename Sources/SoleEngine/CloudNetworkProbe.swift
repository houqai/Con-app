public enum CloudNetworkProbe {
    public struct Measurement: Sendable, Equatable {
        public let rttMs: Int
        public let mtuIn: Int
        public let mtuOut: Int
        public init(rttMs: Int, mtuIn: Int, mtuOut: Int) { self.rttMs = rttMs; self.mtuIn = mtuIn; self.mtuOut = mtuOut }

        static func made(rttMicroseconds rtt: UInt64, mtuIn incoming: UInt32, mtuOut outgoing: UInt32) -> Measurement? {
            guard rtt > 0, rtt < 60_000_000 else { return nil }
            let mtuIn = (576...1454).contains(incoming) ? Int(incoming) : 1454
            let mtuOut = (576...1454).contains(outgoing) ? Int(outgoing) : min(1254, mtuIn)
            return Measurement(rttMs: max(1, Int((rtt + 500) / 1000)), mtuIn: mtuIn, mtuOut: mtuOut)
        }
    }
    public struct Report: Sendable {
        public let measurement: Measurement?
        public let stage: Int
        public let status: Int
        public let engineStage: Int?

        public init(measurement: Measurement?, stage: Int, status: Int, engineStage: Int? = nil) {
            self.measurement = measurement; self.stage = stage; self.status = status; self.engineStage = engineStage
        }
    }
    static func acceptable(host: String, port: UInt16, credential: String) -> Bool {
        !host.isEmpty && port != 0 && !credential.isEmpty && !host.contains("\0") && !credential.contains("\0")
    }
    public static func run(host: String, port: UInt16, credential: String, packetPrefix: UInt8 = 0) -> Report {
        RustCloudProbe.run(host: host, port: port, credential: credential, packetPrefix: packetPrefix)
    }
}
