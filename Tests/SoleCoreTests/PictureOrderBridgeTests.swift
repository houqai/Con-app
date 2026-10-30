import XCTest
@testable import SoleCore

final class PictureOrderBridgeTests: XCTestCase {
    typealias Bridge = PictureOrderBridge
    static let sps = bytes("420101016000000300b00000030000030078a00280802d17139242953b80b50101010400003e90000ea6010480")
    static let pps = bytes("4401c0f3c04c90")
    static let layout = Bridge.Layout(sps: sps, pps: pps)!
    static let tail: [UInt8] = [0x9A, 0, 0, 1, 0x7F, 0, 0, 3, 0x55, 0, 0, 0, 0x80]

    func testReadsTheStreamParameterSets() {
        let layout = Self.layout
        XCTAssertEqual(layout.orderBits, 4)
        XCTAssertTrue(layout.longTermPresent)
        XCTAssertEqual(layout.extraHeaderBits, 0)
        XCTAssertFalse(layout.outputFlagPresent)
        XCTAssertFalse(layout.separateColourPlanes)
        XCTAssertNil(Bridge.Layout(sps: [0x42, 0x01, 0x01], pps: Self.pps))
        XCTAssertNil(Bridge.Layout(sps: Self.sps, pps: [0x44]))
    }

    func testReadsHeadersOfTheStream() throws {
        let ordinary = try XCTUnwrap(Bridge.Header(Self.bytes("0201d29760e14c271d31")[...], layout: Self.layout))
        XCTAssertEqual(ordinary.order, 5)
        XCTAssertEqual(ordinary.earlier, [.init(delta: 1, used: true)])
        XCTAssertEqual(ordinary.longTerm, [.init(order: 0, used: false, cycle: 0), .init(order: 8, used: false, cycle: 1)])
        XCTAssertEqual(ordinary.longTermTargets(at: 37, cycle: 16, held: []), [32, 24])
        let recovery = try XCTUnwrap(Bridge.Header(Self.bytes("0201d01641a61d80e356")[...], layout: Self.layout))
        XCTAssertEqual(recovery.order, 0)
        XCTAssertEqual(recovery.earlier, [.init(delta: 1, used: false)])
        XCTAssertEqual(recovery.longTerm, [.init(order: 0, used: true, cycle: 1)])
        XCTAssertEqual([recovery.start, recovery.end], [5, 28])
        let two = try XCTUnwrap(Bridge.Header(Self.bytes("0201d49679a06c23efde")[...], layout: Self.layout))
        XCTAssertEqual(two.longTerm, [.init(order: 12, used: true, cycle: 1), .init(order: 0, used: false, cycle: 0)])
        XCTAssertEqual(two.longTermTargets(at: 121, cycle: 16, held: []), [108, 96])
        XCTAssertNil(Bridge.Header([0x02, 0x01, 0xD0][...], layout: Self.layout))
    }

    func testFramesThatFollowEachOtherAreLeftAlone() {
        var stream = CloudStream()
        stream.play(through: 37)
        XCTAssertEqual(stream.verdicts.count, 38)
        XCTAssertTrue(stream.verdicts.allSatisfy { $0 == .decode(stones: []) })
        XCTAssertEqual(stream.bridge.bridged, 0)
    }

    func testFrameAfterALongLossGetsASteppingStone() throws {
        var stream = CloudStream()
        stream.play(through: 37)
        let slice = Bridge.escaped(Self.tail)
        let frame = Self.bytes("0201d01641a61d80e356") + slice
        guard case .decode(let stones) = stream.feed(frame, number: 48) else { return XCTFail("rejected") }
        XCTAssertEqual(stones.count, 1)
        let stone = try XCTUnwrap(stones.first)
        XCTAssertEqual(Array(stone.prefix(10)), Self.bytes("0201d69510761d80e356"))
        XCTAssertEqual(Array(stone.dropFirst(10)), slice)
        let header = try XCTUnwrap(Bridge.Header(stone[...], layout: Self.layout))
        XCTAssertEqual(header.order, 13)
        XCTAssertEqual(header.earlier, [.init(delta: 2, used: false)])
        XCTAssertEqual(header.longTerm, [.init(order: 0, used: true, cycle: 0)])
        XCTAssertEqual(header.longTermTargets(at: 45, cycle: 16, held: []), [32])
        XCTAssertEqual(stream.bridge.bridged, 1)
        XCTAssertEqual(stream.feed(CloudStream.picture(49, on: [(32, true)], previousUsed: false), number: 49), .decode(stones: []))
        XCTAssertEqual(stream.feed(CloudStream.picture(50, on: [(32, true)], previousUsed: false), number: 50), .decode(stones: []))
        XCTAssertEqual(stream.bridge.bridged, 1)
    }

    func testStoneKeepsEverythingAfterTheHeader() throws {
        var stream = CloudStream()
        stream.play(through: 37)
        let frame = CloudStream.picture(48, on: [(32, true)], previousUsed: false)
        guard case .decode(let stones) = stream.feed(frame, number: 48), let stone = stones.first else { return XCTFail("no stone") }
        let header = try XCTUnwrap(Bridge.Header(frame[...], layout: Self.layout))
        let original = Bridge.payload(of: frame[...]), changed = Bridge.payload(of: stone[...])
        XCTAssertEqual(original.count, changed.count)
        XCTAssertEqual(original.first! >> 3, changed.first! >> 3, "bits before the picture number")
        XCTAssertEqual(Self.bits(original).dropFirst(header.end), Self.bits(changed).dropFirst(header.end))
        XCTAssertNotEqual(Self.bits(original).prefix(header.end), Self.bits(changed).prefix(header.end))
    }

    func testShortLossNeedsNoStone() {
        var stream = CloudStream()
        stream.play(through: 37)
        XCTAssertEqual(stream.feed(CloudStream.picture(43, on: [(32, true)], previousUsed: false), number: 43), .decode(stones: []))
        XCTAssertEqual(stream.bridge.bridged, 0)
    }

    func testLossOfMoreThanACycleTakesSeveralStones() throws {
        var stream = CloudStream()
        stream.play(through: 37)
        guard case .decode(let stones) = stream.feed(CloudStream.picture(57, on: [(32, true)], previousUsed: false), number: 57) else { return XCTFail("rejected") }
        let headers = try stones.map { try XCTUnwrap(Bridge.Header($0[...], layout: Self.layout)) }
        XCTAssertEqual(headers.map(\.order), [13, 5])
        XCTAssertEqual(headers[0].longTermTargets(at: 45, cycle: 16, held: []), [32])
        XCTAssertEqual(headers[1].longTermTargets(at: 53, cycle: 16, held: []), [32])
        XCTAssertEqual(headers[1].earlier, [.init(delta: 1, used: false)], "nothing to make up for in the frame's own cycle")
    }

    func testSecondLongTermPictureStaysNamed() throws {
        var stream = CloudStream(spacing: 12)
        stream.play(through: 110)
        let frame = CloudStream.picture(121, on: [(108, true), (96, false)], previousUsed: false)
        XCTAssertEqual(Array(frame.prefix(6)), Self.bytes("0201d49679a0"), "the stream's own header")
        guard case .decode(let stones) = stream.feed(frame, number: 121) else { return XCTFail("rejected") }
        XCTAssertEqual(stones.count, 1)
        let header = try XCTUnwrap(Bridge.Header(try XCTUnwrap(stones.first)[...], layout: Self.layout))
        XCTAssertEqual(header.order, 6)
        XCTAssertEqual(header.longTermTargets(at: 118, cycle: 16, held: []), [108, 96])
        XCTAssertEqual(stream.feed(CloudStream.picture(122, on: [(108, true), (96, false)], previousUsed: false), number: 122), .decode(stones: []))
        XCTAssertEqual(stream.feed(CloudStream.picture(133, on: [(96, true)], previousUsed: false), number: 133).stoneCount, 1)
    }

    func testFrameBuiltOnALostPictureIsRejected() {
        var stream = CloudStream()
        stream.play(through: 37)
        XCTAssertEqual(stream.feed(CloudStream.picture(48, on: [(40, true)], previousUsed: false), number: 48), .missingReference)
        XCTAssertEqual(stream.feed(CloudStream.picture(49, on: [(32, true)], previousUsed: false), number: 49).stoneCount, 1)
    }

    func testFrameBuiltOnAShortTermPictureThatWasLostIsRejected() {
        var stream = CloudStream()
        stream.play(through: 37)
        XCTAssertTrue(stream.bridge.follows)
        XCTAssertEqual(stream.feed(CloudStream.picture(41, on: [(32, false), (24, false)]), number: 41), .missingReference)
        XCTAssertEqual(stream.feed(CloudStream.picture(42, on: [(32, true)], previousUsed: false), number: 42), .decode(stones: []))
        XCTAssertTrue(stream.bridge.follows)
    }

    func testLossGatePassesFramesAfterALossUnchanged() {
        var gate = LossGate()
        func unit(_ nal: [UInt8], keyframe: Bool = false) -> VideoStream.Unit { var unit = VideoStream.Unit(); unit.slices = [nal[...]]; unit.isKeyframe = keyframe; return unit }
        func take(_ nal: [UInt8], _ counter: Int, keyframe: Bool = false) -> LossGate.Decision {
            let decision = gate.take(unit(nal, keyframe: keyframe), frame: counter)
            if case .decode = decision { gate.decoded(true) }
            return decision
        }
        XCTAssertEqual(take([0x28, 0x01, 0xAC, 0x25, 0x99, 0x21], 100, keyframe: true), .decode)
        for number in 1...37 {
            XCTAssertEqual(take(CloudStream.picture(number, on: CloudStream.kept(number).map { ($0, false) }), 100 + number), .decode)
        }
        XCTAssertEqual(take(CloudStream.picture(41, on: [(32, false), (24, false)]), 141), .decode)
        XCTAssertEqual(take(CloudStream.picture(48, on: [(32, true)], previousUsed: false), 148), .decode, "No stepping stones: they would renumber pictures the engine is tracking")
        XCTAssertEqual(take(CloudStream.picture(49, on: [(32, false)]), 149), .decode)
    }

    func testLossTooLongToBridgeIsRejected() {
        var stream = CloudStream()
        stream.play(through: 37)
        XCTAssertEqual(stream.feed(CloudStream.picture(237, on: [(32, true)], previousUsed: false), number: 237), .missingReference)
    }

    func testFrameWithoutRoomInItsHeaderIsRejected() {
        var stream = CloudStream()
        stream.play(through: 37)
        XCTAssertEqual(stream.feed(CloudStream.picture(48, on: [(32, true)], previous: false), number: 48), .missingReference)
    }

    func testPaddingTooLongToBeReadBackIsRejected() throws {
        let frame = Self.bytes("0201d01641a61d80e356")
        var header = try XCTUnwrap(Bridge.Header(frame[...], layout: Self.layout))
        header.longTerm = Array(repeating: Bridge.LongTerm(order: 0, used: false, cycle: 63), count: 10) + [Bridge.LongTerm(order: 0, used: true, cycle: 10)]
        XCTAssertNil(header.stone(of: frame[...], at: 0, for: 640 * 16, held: [], layout: Self.layout), "a 127-bit code is longer than the reader accepts")
    }

    func testWithoutFrameCounterNothingIsChanged() {
        var stream = CloudStream()
        stream.counted = false
        stream.play(through: 37)
        XCTAssertEqual(stream.feed(CloudStream.picture(48, on: [(32, true)], previousUsed: false), number: 48), .decode(stones: []))
    }

    func testCounterThatDisagreesWithTheHeaderStopsBridging() {
        var stream = CloudStream()
        stream.play(through: 37)
        XCTAssertEqual(stream.feed(CloudStream.picture(48, on: [(32, true)], previousUsed: false), number: 51), .decode(stones: []))
        XCTAssertEqual(stream.feed(CloudStream.picture(64, on: [(32, true)], previousUsed: false), number: 64), .decode(stones: []))
    }

    func testAfterADecoderFailureNothingIsBridgedUntilAKeyframe() {
        var stream = CloudStream()
        stream.play(through: 37)
        stream.decodes = false
        XCTAssertEqual(stream.feed(CloudStream.picture(38, on: [(32, false)]), number: 38), .decode(stones: []))
        stream.decodes = true
        XCTAssertEqual(stream.feed(CloudStream.picture(49, on: [(32, true)], previousUsed: false), number: 49), .decode(stones: []))
        stream.keyframe(number: 300)
        for number in 1...5 { XCTAssertEqual(stream.feed(CloudStream.picture(number, on: number > 1 ? [(0, false)] : []), number: number), .decode(stones: [])) }
        XCTAssertEqual(stream.feed(CloudStream.picture(16, on: [(0, true)], previousUsed: false), number: 16).stoneCount, 1)
        XCTAssertEqual(stream.bridge.bridged, 1)
    }

    func testCounterWrapsAtSixteenBits() {
        var stream = CloudStream(first: 0xFFF0)
        stream.play(through: 37)
        XCTAssertEqual(stream.feed(CloudStream.picture(48, on: [(32, true)], previousUsed: false), number: 48).stoneCount, 1)
    }

    func testOtherStreamsAreLeftAlone() {
        var bridge = Bridge()
        let frame = CloudStream.picture(48, on: [(32, true)], previousUsed: false)
        XCTAssertEqual(bridge.examine([frame[...]], sps: [0x42, 0x01, 0x01], pps: Self.pps, frame: 1), .decode(stones: []))
        XCTAssertEqual(bridge.examine([frame[...], frame[...]], sps: Self.sps, pps: Self.pps, frame: 2), .decode(stones: []))
        XCTAssertEqual(bridge.examine([([0x00, 0x01] + frame.dropFirst(2))[...]], sps: Self.sps, pps: Self.pps, frame: 3), .decode(stones: []))
        XCTAssertEqual(bridge.examine([], sps: nil, pps: nil, frame: 4), .decode(stones: []))
    }

    func testEmulationPreventionRoundTrip() {
        let payloads: [[UInt8]] = [[1, 2, 3], [0x80, 0, 0, 0, 0], [0x80, 0, 0, 1, 0, 0, 2, 0, 0, 3, 0xFF], [0xAA, 0, 0], [0, 0, 3, 0, 0, 3]]
        for payload in payloads {
            let nal = [0x02, 0x01] + Bridge.escaped(payload)
            XCTAssertEqual(Bridge.payload(of: nal[...]), payload)
            for index in 2..<max(nal.count - 2, 2) {
                XCTAssertFalse(nal[index] == 0 && nal[index + 1] == 0 && nal[index + 2] < 3, "start code inside \(nal)")
            }
            XCTAssertNotEqual(nal.last, 0)
        }
    }

    static func bytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = [], index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return out
    }
    static func bits(_ bytes: [UInt8]) -> [UInt8] { bytes.flatMap { byte in (0..<8).map { (byte >> UInt8(7 - $0)) & 1 } } }
}

private extension PictureOrderBridge.Verdict {
    var stoneCount: Int { if case .decode(let stones) = self { return stones.count } else { return -1 } }
}

private struct CloudStream {
    typealias Bridge = PictureOrderBridge
    var bridge = Bridge()
    var verdicts: [Bridge.Verdict] = []
    let first: Int
    let spacing: Int
    var counted = true
    var decodes = true
    private var keyframeAt: Int

    init(first: Int = 100, spacing: Int = 8) {
        self.first = first
        self.spacing = spacing
        keyframeAt = first
    }

    static func kept(_ number: Int, spacing: Int = 8) -> [Int] {
        let newest = (number - 2) / spacing * spacing
        return number < 2 ? [] : [newest, newest - spacing].filter { $0 >= 0 }
    }

    mutating func play(through last: Int) {
        keyframe(number: first)
        for number in 1...last {
            verdicts.append(feed(Self.picture(number, on: Self.kept(number, spacing: spacing).map { ($0, false) }), number: number))
        }
    }
    mutating func keyframe(number: Int) {
        keyframeAt = number
        verdicts.append(examine([0x28, 0x01, 0xAC, 0x25, 0x99, 0x21], counter: number))
    }
    mutating func feed(_ nal: [UInt8], number: Int) -> Bridge.Verdict { examine(nal, counter: keyframeAt + number) }

    private mutating func examine(_ nal: [UInt8], counter: Int) -> Bridge.Verdict {
        let verdict = bridge.examine([nal[...]], sps: PictureOrderBridgeTests.sps, pps: PictureOrderBridgeTests.pps, frame: counted ? counter & 0xFFFF : nil)
        if case .decode = verdict { bridge.finish(decoded: decodes) }
        return verdict
    }

    static func picture(_ number: Int, on longTerm: [(picture: Int, used: Bool)], previous: Bool = true, previousUsed: Bool = true) -> [UInt8] {
        var writer = Bridge.BitWriter()
        writer.bits(1, 1)
        writer.exp(0)
        writer.exp(1)
        writer.bits(number & 15, 4)
        writer.bits(0, 1)
        writer.exp(previous ? 1 : 0)
        writer.exp(0)
        if previous {
            writer.exp(0)
            writer.bits(previousUsed ? 1 : 0, 1)
        }
        writer.exp(longTerm.count)
        var back = 0
        for entry in longTerm {
            let cycles = ((number - (number & 15)) - (entry.picture - (entry.picture & 15))) / 16
            writer.bits(entry.picture & 15, 4)
            writer.bits(entry.used ? 1 : 0, 1)
            writer.bits(1, 1)
            writer.exp(cycles - back)
            back = cycles
        }
        writer.bits(0b0110, 4)
        while writer.out.count % 8 != 0 { writer.bits(1, 1) }
        var payload: [UInt8] = []
        for start in stride(from: 0, to: writer.out.count, by: 8) { payload.append(writer.out[start..<start + 8].reduce(0) { $0 << 1 | $1 }) }
        return [0x02, 0x01] + Bridge.escaped(payload + PictureOrderBridgeTests.tail)
    }
}
