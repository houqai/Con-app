import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum Gzip {
    public static func isGzip(_ data: Data) -> Bool {
        data.count >= 18 && data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b && data[data.startIndex + 2] == 8
    }

    public static func unpack(_ data: Data, limit: Int = 64 << 20) -> Data? {
        guard isGzip(data) else { return nil }
        let bytes = [UInt8](data)
        let flags = bytes[3]
        var at = 10
        if flags & 4 != 0 {
            guard at + 2 <= bytes.count else { return nil }
            at += 2 + (Int(bytes[at]) | Int(bytes[at + 1]) << 8)
        }
        for flag: UInt8 in [8, 16] where flags & flag != 0 {
            while at < bytes.count, bytes[at] != 0 { at += 1 }
            at += 1
        }
        if flags & 2 != 0 { at += 2 }
        guard at + 8 < bytes.count else { return nil }
        var inflater = Inflater(input: bytes, at: at, limit: limit)
        guard inflater.run() else { return nil }
        let end = inflater.byte
        guard end + 8 <= bytes.count else { return nil }
        func word(_ at: Int) -> UInt32 { UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24 }
        guard word(end + 4) == UInt32(truncatingIfNeeded: inflater.output.count), word(end) == checksum(inflater.output) else { return nil }
        return Data(inflater.output)
    }

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    private struct Inflater {
        let input: [UInt8]
        var byte: Int
        let limit: Int
        var output: [UInt8] = []
        private var hold: UInt32 = 0
        private var held = 0

        init(input: [UInt8], at: Int, limit: Int) { self.input = input; byte = at; self.limit = limit }

        private mutating func bits(_ count: Int) -> Int? {
            while held < count {
                guard byte < input.count else { return nil }
                hold |= UInt32(input[byte]) << UInt32(held)
                byte += 1; held += 8
            }
            let value = Int(hold & ((UInt32(1) << UInt32(count)) - 1))
            hold >>= UInt32(count); held -= count
            return value
        }

        private struct Code {
            var counts = [Int](repeating: 0, count: 16)
            var symbols: [Int]
            let left: Int
            init(_ lengths: ArraySlice<Int>) {
                symbols = [Int](repeating: 0, count: lengths.count)
                for length in lengths { counts[length] += 1 }
                var left = 1
                for length in 1...15 where left >= 0 { left = left * 2 - counts[length] }
                self.left = left
                guard left >= 0 else { return }
                var offsets = [Int](repeating: 0, count: 16)
                for length in 1..<15 { offsets[length + 1] = offsets[length] + counts[length] }
                for (symbol, length) in lengths.enumerated() where length != 0 {
                    symbols[offsets[length]] = symbol
                    offsets[length] += 1
                }
            }
        }

        private mutating func symbol(_ code: Code) -> Int? {
            var value = 0, first = 0, index = 0
            for length in 1...15 {
                guard let bit = bits(1) else { return nil }
                value |= bit
                let count = code.counts[length]
                if value - count < first { return code.symbols[index + (value - first)] }
                index += count; first += count
                first <<= 1; value <<= 1
            }
            return nil
        }

        private static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
        private static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
        private static let distanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
        private static let distanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
        private static let fixed: (lengths: Code, distances: Code) = {
            let lengths = [Int](repeating: 8, count: 144) + [Int](repeating: 9, count: 112) + [Int](repeating: 7, count: 24) + [Int](repeating: 8, count: 8)
            return (Code(lengths[...]), Code([Int](repeating: 5, count: 30)[...]))
        }()

        private mutating func block(_ lengths: Code, _ distances: Code) -> Bool {
            while true {
                guard let value = symbol(lengths) else { return false }
                if value < 256 {
                    guard output.count < limit else { return false }
                    output.append(UInt8(value))
                } else if value == 256 {
                    return true
                } else {
                    let index = value - 257
                    guard index < 29, let more = bits(Self.lengthExtra[index]), let place = symbol(distances), place < 30,
                          let further = bits(Self.distanceExtra[place]) else { return false }
                    let length = Self.lengthBase[index] + more, distance = Self.distanceBase[place] + further
                    guard distance <= output.count, output.count + length <= limit else { return false }
                    var from = output.count - distance
                    for _ in 0..<length { output.append(output[from]); from += 1 }
                }
            }
        }

        private mutating func stored() -> Bool {
            hold = 0; held = 0
            guard byte + 4 <= input.count else { return false }
            let length = Int(input[byte]) | Int(input[byte + 1]) << 8
            guard length == (~(Int(input[byte + 2]) | Int(input[byte + 3]) << 8)) & 0xFFFF else { return false }
            byte += 4
            guard byte + length <= input.count, output.count + length <= limit else { return false }
            output.append(contentsOf: input[byte..<byte + length])
            byte += length
            return true
        }

        private mutating func dynamic() -> Bool {
            guard let literals = bits(5), let places = bits(5), let codes = bits(4) else { return false }
            let lengthCount = literals + 257, distanceCount = places + 1
            guard lengthCount <= 286, distanceCount <= 30 else { return false }
            let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
            var lengths = [Int](repeating: 0, count: 19)
            for index in 0..<(codes + 4) {
                guard let length = bits(3) else { return false }
                lengths[order[index]] = length
            }
            let lengthCode = Code(lengths[...])
            guard lengthCode.left == 0 else { return false }
            lengths = [Int](repeating: 0, count: lengthCount + distanceCount)
            var index = 0
            while index < lengths.count {
                guard let value = symbol(lengthCode) else { return false }
                if value < 16 { lengths[index] = value; index += 1; continue }
                var repeated = 0, times = 0
                if value == 16 {
                    guard index > 0, let more = bits(2) else { return false }
                    repeated = lengths[index - 1]; times = 3 + more
                } else if value == 17 {
                    guard let more = bits(3) else { return false }
                    times = 3 + more
                } else {
                    guard let more = bits(7) else { return false }
                    times = 11 + more
                }
                guard index + times <= lengths.count else { return false }
                for _ in 0..<times { lengths[index] = repeated; index += 1 }
            }
            guard lengths[256] != 0 else { return false }
            let literalCode = Code(lengths[..<lengthCount]), distanceCode = Code(lengths[lengthCount...])
            guard literalCode.left == 0 || (literalCode.left > 0 && lengthCount == literalCode.counts[0] + literalCode.counts[1]),
                  distanceCode.left == 0 || (distanceCode.left > 0 && distanceCount == distanceCode.counts[0] + distanceCode.counts[1]) else { return false }
            return block(literalCode, distanceCode)
        }

        mutating func run() -> Bool {
            while true {
                guard let last = bits(1), let kind = bits(2) else { return false }
                let decoded: Bool
                switch kind {
                case 0: decoded = stored()
                case 1: decoded = block(Self.fixed.lengths, Self.fixed.distances)
                case 2: decoded = dynamic()
                default: decoded = false
                }
                guard decoded else { return false }
                if last == 1 { hold = 0; held = 0; return true }
            }
        }
    }
}

public enum HTTPBody {
    public static func plain(_ data: Data, _ response: URLResponse) -> Data {
        guard let http = response as? HTTPURLResponse,
              (http.value(forHTTPHeaderField: "Content-Encoding") ?? "").lowercased().contains("gzip"),
              let unpacked = Gzip.unpack(data) else { return data }
        return unpacked
    }
}

extension URLSession {
    public func plainData(for request: URLRequest) async throws -> (Data, URLResponse) {
        let (data, response) = try await data(for: request)
        return (HTTPBody.plain(data, response), response)
    }
    public func plainData(from url: URL) async throws -> (Data, URLResponse) {
        let (data, response) = try await data(from: url)
        return (HTTPBody.plain(data, response), response)
    }
}
