import Foundation

public struct CloudLaunchSlot: Sendable, CustomStringConvertible {
    public let publicIp: String
    public let port: Int
    public let privateIp: String?
    public let handshakeKey: Data
    public let launchSpecification: String
    public let sessionId: String

    public var psnWrapperType: UInt8? {
        guard let privateIp, CloudDatacenter.validIPv4(privateIp), let last = privateIp.split(separator: ".").last else { return nil }
        return UInt8(last)
    }
    public var description: String { "CloudLaunchSlot(\(publicIp):\(port), key: <redacted>)" }
}

public enum CloudAllocation: Sendable {
    case ready(CloudLaunchSlot)
    case queued(position: Int?, waitEstimate: Int?, pollFrequency: Int)
    case migrating(percent: Int?, pollFrequency: Int)

    public enum Failure: Error, Equatable { case invalidSlot, queueTimeout(position: Int?) }

    public static func decode(_ data: Data) throws -> CloudAllocation {
        guard data.count < 2_000_000,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw Failure.invalidSlot }
        if object["dataMigration"] as? Bool == true {
            return .migrating(percent: integer(object["dataMigrationPercentageComplete"]), pollFrequency: integer(object["pollFrequency"]) ?? 15)
        }
        if object["queued"] as? Bool == true {
            return .queued(position: integer(object["displayQueuePosition"]) ?? integer(object["queuePosition"]), waitEstimate: integer(object["waitTimeEstimate"]),
                           pollFrequency: integer(object["pollFrequency"]) ?? 15)
        }
        if let slot = object["launchSlot"] as? [String: Any] {
            return .ready(try parseSlot(slot, root: object))
        }
        throw Failure.invalidSlot
    }

    private static func parseSlot(_ slot: [String: Any], root: [String: Any]) throws -> CloudLaunchSlot {
        guard let ip = slot["publicIp"] as? String, CloudDatacenter.validIPv4(ip) || CloudDatacenter.validIPv6(ip),
              let port = integer(slot["port"]), (1...65535).contains(port),
              let keyText = (slot["handshakeKey"] ?? root["handshakeKey"]) as? String, let key = Data(base64Encoded: keyText), key.count == 16,
              let session = (slot["sessionId"] ?? root["sessionId"]) as? String, !session.isEmpty, session.count <= 128,
              session.allSatisfy({ $0.isASCII && !$0.isWhitespace && !$0.isNewline }) else { throw Failure.invalidSlot }
        let privateIp = slot["privateIp"] as? String
        if let privateIp, !(CloudDatacenter.validIPv4(privateIp) || CloudDatacenter.validIPv6(privateIp)) { throw Failure.invalidSlot }
        let specification: String
        switch slot["launchSpecification"] ?? root["launchSpecification"] {
        case let text as String: specification = text
        case let value? where JSONSerialization.isValidJSONObject(value):
            specification = String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        default: specification = ""
        }
        guard specification.utf8.count < 1_000_000 else { throw Failure.invalidSlot }
        return CloudLaunchSlot(publicIp: ip, port: port, privateIp: privateIp, handshakeKey: key, launchSpecification: specification, sessionId: session)
    }

    static func integer(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber where number !== NSNumber(value: true) && number !== NSNumber(value: false):
            let value = number.doubleValue
            guard value.isFinite, value.rounded(.towardZero) == value, let integer = Int(exactly: value) else { return nil }
            return integer
        case let text as String: return Int(text)
        default: return nil
        }
    }
}

public enum CloudQueuePolicy {
    public static let maximumWait: TimeInterval = 900
    public static func deadline(estimate: Int?) -> TimeInterval {
        guard let estimate, estimate > 0 else { return maximumWait }
        return min(TimeInterval(estimate) * 2, maximumWait)
    }
    public static func pollInterval(_ frequency: Int) -> TimeInterval { TimeInterval(min(max(frequency, 5), 60)) }
}

public struct CloudNetworkEstimate: Sendable {
    public var port: UInt16
    public var rttMs: Int
    public var bwKbpsReceived = 200_000
    public var bwKbpsSent = 50_000
    public var bwLoss = 0.001
    public var bwLossUpstream = 0.0
    public var mtu = 1454
    public var mtuUpstream = 1254
    public var stateExecutionTimeMs: Double = 0
    public var streamTestTimeMs: Double = 0
    public init(port: UInt16, rttMs: Int = 25) { self.port = port; self.rttMs = min(max(rttMs, 1), 1000) }
    var json: [String: Any] {
        ["bwKbpsSent": bwKbpsSent, "bwLoss": bwLoss, "mtu": mtu, "rtt": rttMs, "port": Int(port),
         "bwKbpsReceived": bwKbpsReceived, "bwLossUpstream": bwLossUpstream, "mtuUpstream": mtuUpstream]
    }
}
