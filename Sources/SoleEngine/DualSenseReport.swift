import Foundation

public struct DualSenseReport: Sendable {
    public var effects = [UInt8](repeating: 0, count: 47)
    public init() {}
    public mutating func triggers(left: [UInt8], right: [UInt8]) {
        guard left.count == 11, right.count == 11 else { return }
        effects[0] |= 0x0c
        effects.replaceSubrange(10..<21, with: right)
        effects.replaceSubrange(21..<32, with: left)
    }
    public mutating func rumble(left: UInt8, right: UInt8) {
        effects[0] |= 0x03
        effects[2] = right / 2; effects[3] = left / 2
    }
    public var selectsRumble: Bool { effects[0] & 0x03 != 0 }
    public mutating func led(red: UInt8, green: UInt8, blue: UInt8) {
        effects[1] |= 0x04
        effects[44] = red; effects[45] = green; effects[46] = blue
    }
    public mutating func light(red: UInt8, green: UInt8, blue: UInt8) {
        if red == 0, green == 0, blue == 0 { led(red: Self.ownLight.red, green: Self.ownLight.green, blue: Self.ownLight.blue) }
        else { led(red: red, green: green, blue: blue) }
    }
    public static let ownLight: (red: UInt8, green: UInt8, blue: UInt8) = (0, 72, 255)
    public mutating func player(_ index: UInt8) {
        let lights: [UInt8] = [0x04, 0x0a, 0x15, 0x1b, 0x1f]
        effects[1] |= 0x10
        effects[43] = index == 0 ? 0 : lights[Int(index - 1) % lights.count]
    }
    public func packet(bluetooth: Bool) -> [UInt8] {
        var packet = [UInt8](repeating: 0, count: bluetooth ? 78 : 48)
        packet[0] = bluetooth ? 0x31 : 0x02
        let offset = bluetooth ? 2 : 1
        if bluetooth { packet[1] = 0x02 }
        packet.replaceSubrange(offset..<(offset + 47), with: effects)
        if bluetooth {
            let checksum = Self.crc32([0xa2] + Array(packet.prefix(74)))
            for i in 0..<4 { packet[74 + i] = UInt8(truncatingIfNeeded: checksum >> (i * 8)) }
        }
        return packet
    }
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var value: UInt32 = 0xffffffff
        for byte in bytes {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = value & 1 == 1 ? (value >> 1) ^ 0xedb88320 : value >> 1 }
        }
        return ~value
    }
}
