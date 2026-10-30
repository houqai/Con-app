import Foundation

public struct PictureOrderBridge: Sendable {
    public enum Verdict: Equatable, Sendable {
        case decode(stones: [[UInt8]])
        case missingReference
    }

    private struct State: Sendable {
        var order: Int
        var frame: Int?
        var held: Set<Int>
    }
    private enum Outcome: Sendable { case state(State, bridged: Bool), unknown }

    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var layout: Layout?
    private var state: State?
    private var pending: Outcome?
    public private(set) var bridged = 0

    static let stoneLimit = 8

    public init() {}

    public var follows: Bool { state != nil }

    public mutating func reset() { state = nil; pending = nil }

    public mutating func examine(_ slices: [ArraySlice<UInt8>], sps: [UInt8]?, pps: [UInt8]?, frame: Int?) -> Verdict {
        pending = .unknown
        if sps != self.sps || pps != self.pps {
            self.sps = sps; self.pps = pps; state = nil
            layout = sps.flatMap { sps in pps.flatMap { Layout(sps: sps, pps: $0) } }
        }
        guard let layout, slices.count == 1, let nal = slices.first, nal.count > 2 else { return .decode(stones: []) }
        let type = Int(nal[nal.startIndex] >> 1) & 0x3F
        if type == 19 || type == 20 {
            pending = .state(State(order: 0, frame: frame, held: [0]), bridged: false)
            return .decode(stones: [])
        }
        guard type == 1, nal[nal.startIndex + 1] & 7 == 1, let state, let header = Header(nal, layout: layout) else { return .decode(stones: []) }
        let cycle = 1 << layout.orderBits, mask = cycle - 1
        let forward = (header.order - state.order) & mask
        let natural = forward <= cycle / 2 ? state.order + forward : state.order - (cycle - forward)
        var order = natural
        var missing = false
        if let frame, let before = state.frame {
            let gap = (frame - before) & 0xFFFF
            guard gap >= 1, gap < 0x8000, (state.order + gap) & mask == header.order else { return .decode(stones: []) }
            missing = gap > 1
            if header.longTerm.contains(where: { $0.used && $0.cycle != nil }) { order = state.order + gap }
        }
        if missing || order != natural {
            for target in header.longTermTargets(at: order, cycle: cycle, held: state.held, usedOnly: true) where !state.held.contains(target) {
                pending = nil
                return .missingReference
            }
            if missing, !header.shortTermTargets(at: order, usedOnly: true).isSubset(of: state.held) {
                pending = nil
                return .missingReference
            }
        }
        var stones: [[UInt8]] = []
        var held = state.held
        if order != natural {
            var step = state.order
            while order - step > cycle / 2 {
                step += cycle / 2
                guard stones.count < Self.stoneLimit, let stone = header.stone(of: nal, at: step, for: order, held: held, layout: layout) else {
                    pending = nil
                    return .missingReference
                }
                stones.append(stone.bytes)
                held = stone.header.references(at: step, cycle: cycle, held: held).intersection(held).union([step])
            }
        }
        held = header.references(at: order, cycle: cycle, held: held).intersection(held).union([order])
        pending = .state(State(order: order, frame: frame, held: held), bridged: !stones.isEmpty)
        return .decode(stones: stones)
    }

    public mutating func finish(decoded: Bool) {
        defer { pending = nil }
        guard let pending else { return }
        if decoded, case let .state(next, bridged) = pending {
            state = next
            if bridged { self.bridged += 1 }
        } else {
            state = nil
        }
    }
}

extension PictureOrderBridge {
    struct Layout: Equatable, Sendable {
        var orderBits = 4
        var extraHeaderBits = 0
        var outputFlagPresent = false
        var separateColourPlanes = false
        var longTermPresent = false

        init?(sps: [UInt8], pps: [UInt8]) {
            guard sps.count > 2, pps.count > 2 else { return nil }
            do {
                var r = BitReader(PictureOrderBridge.payload(of: sps[...]))
                try r.skip(4)
                let subLayers = try r.bits(3)
                try r.skip(1 + 96)
                if subLayers > 0 {
                    var present: [(Bool, Bool)] = []
                    for _ in 0..<subLayers { present.append((try r.bits(1) == 1, try r.bits(1) == 1)) }
                    try r.skip(2 * (8 - subLayers))
                    for (profile, level) in present { try r.skip((profile ? 88 : 0) + (level ? 8 : 0)) }
                }
                _ = try r.exp()
                if try r.exp() == 3 { separateColourPlanes = try r.bits(1) == 1 }
                _ = try r.exp(); _ = try r.exp()
                if try r.bits(1) == 1 { for _ in 0..<4 { _ = try r.exp() } }
                _ = try r.exp(); _ = try r.exp()
                orderBits = try r.exp() + 4
                guard orderBits <= 16 else { return nil }
                let ordering = try r.bits(1) == 1
                for _ in (ordering ? 0 : subLayers)...subLayers { for _ in 0..<3 { _ = try r.exp() } }
                for _ in 0..<6 { _ = try r.exp() }
                if try r.bits(1) == 1, try r.bits(1) == 1 { return nil }
                try r.skip(2)
                if try r.bits(1) == 1 {
                    try r.skip(8); _ = try r.exp(); _ = try r.exp(); try r.skip(1)
                }
                guard try r.exp() == 0 else { return nil }
                longTermPresent = try r.bits(1) == 1
                if longTermPresent, try r.exp() != 0 { return nil }

                var p = BitReader(PictureOrderBridge.payload(of: pps[...]))
                _ = try p.exp(); _ = try p.exp()
                try p.skip(1)
                outputFlagPresent = try p.bits(1) == 1
                extraHeaderBits = try p.bits(3)
            } catch { return nil }
        }
    }

    struct ShortTerm: Equatable, Sendable { var delta: Int; var used: Bool }
    struct LongTerm: Equatable, Sendable {
        var order: Int
        var used: Bool
        var cycle: Int?
    }

    struct Header: Equatable, Sendable {
        var order = 0
        var earlier: [ShortTerm] = []
        var later: [ShortTerm] = []
        var longTerm: [LongTerm] = []
        var start = 0
        var end = 0

        init?(_ nal: ArraySlice<UInt8>, layout: Layout) {
            do {
                var r = BitReader(PictureOrderBridge.payload(of: nal.prefix(98)))
                guard try r.bits(1) == 1 else { return nil }
                _ = try r.exp()
                try r.skip(layout.extraHeaderBits)
                _ = try r.exp()
                try r.skip((layout.outputFlagPresent ? 1 : 0) + (layout.separateColourPlanes ? 2 : 0))
                start = r.position
                order = try r.bits(layout.orderBits)
                guard try r.bits(1) == 0 else { return nil }
                let before = try r.exp(), after = try r.exp()
                guard before <= 16, after <= 16 else { return nil }
                for _ in 0..<before { earlier.append(ShortTerm(delta: try r.exp() + 1, used: try r.bits(1) == 1)) }
                for _ in 0..<after { later.append(ShortTerm(delta: try r.exp() + 1, used: try r.bits(1) == 1)) }
                if layout.longTermPresent {
                    let count = try r.exp()
                    guard count <= 32 else { return nil }
                    for _ in 0..<count {
                        let order = try r.bits(layout.orderBits), used = try r.bits(1) == 1
                        longTerm.append(LongTerm(order: order, used: used, cycle: try r.bits(1) == 1 ? try r.exp() : nil))
                    }
                }
                end = r.position
            } catch { return nil }
        }

        func bits(_ layout: Layout) -> [UInt8] {
            var w = BitWriter()
            w.bits(order, layout.orderBits); w.bits(0, 1)
            w.exp(earlier.count); w.exp(later.count)
            for entry in earlier + later { w.exp(entry.delta - 1); w.bits(entry.used ? 1 : 0, 1) }
            if layout.longTermPresent {
                w.exp(longTerm.count)
                for entry in longTerm {
                    w.bits(entry.order, layout.orderBits); w.bits(entry.used ? 1 : 0, 1)
                    w.bits(entry.cycle == nil ? 0 : 1, 1)
                    if let cycle = entry.cycle { w.exp(cycle) }
                }
            }
            return w.out
        }

        func longTermTargets(at order: Int, cycle: Int, held: Set<Int>, usedOnly: Bool = false) -> [Int] {
            var targets: [Int] = [], back = 0
            for entry in longTerm {
                back += entry.cycle ?? 0
                guard entry.used || !usedOnly else { continue }
                if entry.cycle != nil {
                    targets.append(order - (order & (cycle - 1)) - back * cycle + entry.order)
                } else if let match = held.filter({ $0 & (cycle - 1) == entry.order }).max() {
                    targets.append(match)
                } else if usedOnly {
                    targets.append(Int.min)
                }
            }
            return targets
        }

        func shortTermTargets(at order: Int, usedOnly: Bool) -> Set<Int> {
            var all = Set<Int>(), distance = 0
            for entry in earlier { distance += entry.delta; if entry.used || !usedOnly { all.insert(order - distance) } }
            distance = 0
            for entry in later { distance += entry.delta; if entry.used || !usedOnly { all.insert(order + distance) } }
            return all
        }

        func references(at order: Int, cycle: Int, held: Set<Int>) -> Set<Int> {
            var all = Set(longTermTargets(at: order, cycle: cycle, held: held))
            var distance = 0
            for entry in earlier { distance += entry.delta; all.insert(order - distance) }
            distance = 0
            for entry in later { distance += entry.delta; all.insert(order + distance) }
            return all
        }

        func stone(of nal: ArraySlice<UInt8>, at step: Int, for order: Int, held: Set<Int>, layout: Layout) -> (bytes: [UInt8], header: Header)? {
            let cycle = 1 << layout.orderBits, mask = cycle - 1
            let shift = ((order - (order & mask)) - (step - (step & mask))) / cycle
            guard shift >= 0 else { return nil }
            var stone = self
            stone.order = step & mask
            var saved = 0, back = 0, stoneBack = 0
            for index in longTerm.indices {
                guard let coded = longTerm[index].cycle else { continue }
                back += coded
                guard back >= shift || !longTerm[index].used else { return nil }
                let wanted = max(0, back - shift)
                stone.longTerm[index].cycle = wanted - stoneBack
                saved += BitWriter.expLength(coded) - BitWriter.expLength(wanted - stoneBack)
                stoneBack = wanted
            }
            if saved != 0 {
                guard saved > 0, saved % 2 == 0, let last = earlier.last, !last.used else { return nil }
                let length = BitWriter.expLength(last.delta - 1) + saved
                let half = (length - 1) / 2
                guard half <= 24 else { return nil }
                let before = earlier.dropLast().reduce(0) { $0 + $1.delta }
                let codes = ((1 << half) - 1)..<((1 << (half + 1)) - 1)
                let code = codes.first { !held.contains(step - before - $0 - 1) } ?? codes.lowerBound
                stone.earlier[stone.earlier.count - 1].delta = code + 1
            }
            let bits = stone.bits(layout)
            var body = PictureOrderBridge.payload(of: nal)
            guard bits.count == end - start, end <= body.count * 8 else { return nil }
            let original = self.bits(layout)
            guard original.count == bits.count,
                  original.indices.allSatisfy({ original[$0] == (body[(start + $0) >> 3] >> UInt8(7 - (start + $0) & 7)) & 1 }) else { return nil }
            for (offset, bit) in bits.enumerated() {
                let position = start + offset, flag = UInt8(0x80) >> UInt8(position & 7)
                if bit == 1 { body[position >> 3] |= flag } else { body[position >> 3] &= ~flag }
            }
            return (Array(nal.prefix(2)) + PictureOrderBridge.escaped(body), stone)
        }
    }

    static func payload(of nal: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(nal.count)
        var zeros = 0
        for byte in nal.dropFirst(2) {
            if zeros >= 2, byte == 3 { zeros = 0; continue }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return out
    }

    static func escaped(_ payload: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(payload.count + payload.count / 64 + 1)
        var zeros = 0
        for byte in payload {
            if zeros >= 2, byte <= 3 { out.append(3); zeros = 0 }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        if payload.last == 0 { out.append(3) }
        return out
    }

    struct BitReader {
        struct End: Error {}
        let bytes: [UInt8]
        var position = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }
        mutating func bits(_ count: Int) throws -> Int {
            guard count <= 32, position + count <= bytes.count * 8 else { throw End() }
            var value = 0
            for _ in 0..<count {
                value = value << 1 | Int(bytes[position >> 3] >> UInt8(7 - position & 7)) & 1
                position += 1
            }
            return value
        }
        mutating func skip(_ count: Int) throws {
            guard position + count <= bytes.count * 8 else { throw End() }
            position += count
        }
        mutating func exp() throws -> Int {
            var zeros = 0
            while try bits(1) == 0 { zeros += 1; guard zeros <= 24 else { throw End() } }
            return (1 << zeros) - 1 + (try bits(zeros))
        }
    }

    struct BitWriter {
        var out: [UInt8] = []
        mutating func bits(_ value: Int, _ count: Int) {
            for index in stride(from: count - 1, through: 0, by: -1) { out.append(UInt8(value >> index & 1)) }
        }
        mutating func exp(_ value: Int) {
            let length = Self.expLength(value)
            bits(0, length / 2); bits(value + 1, length / 2 + 1)
        }
        static func expLength(_ value: Int) -> Int { 2 * (Int.bitWidth - (value + 1).leadingZeroBitCount) - 1 }
    }
}
