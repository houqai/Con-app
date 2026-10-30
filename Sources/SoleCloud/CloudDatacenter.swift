import Foundation

public struct CloudDatacenter: Decodable, Identifiable, Sendable {
    public enum Failure: Error { case emptyList, invalidName, invalidAddress, invalidPort, duplicate, invalidSchema, unreachable, probeTimeout }
    public let dataCenter: String
    public let publicIp: String
    public let port: Int
    public let maxBandwidth: Int?
    public var id: String { dataCenter }
    private enum CodingKeys: String, CodingKey { case dataCenter, publicIp, port, maxBandwidth }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        dataCenter = try values.decode(String.self, forKey: .dataCenter)
        publicIp = try values.decode(String.self, forKey: .publicIp)
        maxBandwidth = try values.decodeIfPresent(Int.self, forKey: .maxBandwidth)
        if let number = try? values.decode(Int.self, forKey: .port) { port = number }
        else {
            let text = try values.decode(String.self, forKey: .port)
            guard let number = Int(text), (1...65535).contains(number) else { throw Failure.invalidPort }
            port = number
        }
    }
    public static func decode(_ data: Data) throws -> [CloudDatacenter] {
        guard data.count < 2_000_000 else { throw CloudProtocol.Failure.invalidResponse }
        let centers: [CloudDatacenter]
        do { centers = try JSONDecoder().decode([CloudDatacenter].self, from: unwrapList(data)).filter { !$0.publicIp.isEmpty } }
        catch { throw Failure.invalidSchema }
        guard !centers.isEmpty else { throw Failure.emptyList }
        guard centers.count <= 100 else { throw Failure.invalidSchema }
        guard Set(centers.map(\.id)).count == centers.count else { throw Failure.duplicate }
        for center in centers {
            guard validName(center.id) else { throw Failure.invalidName }
            guard (1...65535).contains(center.port) else { throw Failure.invalidPort }
            guard validAddress(center.publicIp) else { throw Failure.invalidAddress }
        }
        return centers
    }
    static let listKeys = ["dataCenters", "datacenters", "dataCenterList", "datacenterList"]
    static func unwrapList(_ data: Data) throws -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return data }
        for key in listKeys {
            if let list = object[key] as? [Any] { return try JSONSerialization.data(withJSONObject: list) }
        }
        return data
    }
    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 128 && name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_-. ".contains($0)) })
    }
    public static func choose(_ centers: [CloudDatacenter], latencies: [String: Int], preferred: String?) -> CloudDatacenter? {
        if let preferred, let match = centers.first(where: { $0.id == preferred }) { return match }
        let measured = centers.compactMap { center in latencies[center.id].map { (center, $0) } }
        return measured.min { $0.1 < $1.1 }?.0 ?? centers.first
    }
    static func validAddress(_ value: String) -> Bool {
        if validIPv4(value) || validIPv6(value) { return true }
        guard value.utf8.count <= 253 else { return false }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.last?.contains(where: { $0.isASCII && $0.isLetter }) == true else { return false }
        return labels.allSatisfy {
            !$0.isEmpty && $0.count <= 63 && $0.first != "-" && $0.last != "-" &&
            $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
    static func validIPv6(_ value: String) -> Bool {
        guard value.utf8.count <= 45, value.contains(":") else { return false }
        let halves = value.components(separatedBy: "::")
        guard halves.count <= 2 else { return false }
        func groups(_ part: String, last: Bool) -> Int? {
            if part.isEmpty { return 0 }
            let pieces = part.split(separator: ":", omittingEmptySubsequences: false)
            var count = 0
            for (index, piece) in pieces.enumerated() {
                if last, index == pieces.count - 1, piece.contains(".") {
                    guard validIPv4(String(piece)) else { return nil }
                    count += 2
                } else {
                    guard (1...4).contains(piece.count), piece.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
                    count += 1
                }
            }
            return count
        }
        if halves.count == 1 { return groups(halves[0], last: true) == 8 }
        guard let head = groups(halves[0], last: false), let tail = groups(halves[1], last: true) else { return false }
        return head + tail <= 7
    }
    static func validIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy {
            !$0.isEmpty && $0.count <= 3 && ($0.count == 1 || $0.first != "0") &&
            $0.allSatisfy({ $0.isASCII && $0.isNumber }) && UInt8($0) != nil
        }
    }
}

public enum CloudPingPolicy {
    public static let limitMs = 80
    public static let substituteMs = 75
    public static func reported(_ measuredMs: Int, distant: Bool) -> Int { distant && measuredMs > limitMs ? substituteMs : measuredMs }
    public struct TooFar: Error, Equatable {
        public let ms: Int
        public init(ms: Int) { self.ms = ms }
    }
}

public struct CloudPingResult: Sendable {
    public let center: CloudDatacenter
    public let rttMs: Int?
    public let mtuIn: Int
    public let mtuOut: Int
    public init(center: CloudDatacenter, rttMs: Int?, mtuIn: Int = 1454, mtuOut: Int = 1254) {
        self.center = center; self.rttMs = rttMs; self.mtuIn = mtuIn; self.mtuOut = mtuOut
    }
    var json: [String: Any] {
        let rtt = rttMs ?? 999
        return ["dataCenter": center.id, "rtt": rtt, "rtts": [rtt], "mtu_in": rttMs == nil ? 0 : mtuIn, "mtu_out": rttMs == nil ? 0 : mtuOut,
                "port": center.port, "publicIp": center.publicIp, "maxBandwidth": center.maxBandwidth ?? 0, "measured": rttMs != nil]
    }
    public static func ordered(_ results: [CloudPingResult], selected: String, exclusive: Bool, distant: Bool) -> [CloudPingResult] {
        guard let measured = results.first(where: { $0.center.id == selected }) else { return [] }
        let chosen = CloudPingResult(center: measured.center, rttMs: measured.rttMs.map { CloudPingPolicy.reported($0, distant: distant) }, mtuIn: measured.mtuIn, mtuOut: measured.mtuOut)
        if exclusive { return [chosen] }
        let others = results.filter { $0.center.id != selected }.sorted { ($0.rttMs ?? Int.max, $0.center.id) < ($1.rttMs ?? Int.max, $1.center.id) }
        return [chosen] + others
    }
}
