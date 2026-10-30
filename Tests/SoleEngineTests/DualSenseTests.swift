import Testing
@testable import SoleEngine

@Suite struct DualSenseTests {
    @Test func forwardsExactServerTriggerEffectsWithoutSwappingSides() {
        var report = DualSenseReport()
        let left: [UInt8] = [0x21, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        let right: [UInt8] = [0x26, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1]
        report.triggers(left: left, right: right)
        let usb = report.packet(bluetooth: false)
        #expect(usb.count == 48 && usb[0] == 0x02)
        #expect(usb[1] == 0x0c)
        #expect(Array(usb[11..<22]) == right)
        #expect(Array(usb[22..<33]) == left)
        #expect(report.packet(bluetooth: true).count == 78)
    }
    @Test func bluetoothChecksumIncludesHIDPHeader() {
        #expect(DualSenseReport.crc32(Array("123456789".utf8)) == 0xcbf43926)
        let packet = DualSenseReport().packet(bluetooth: true)
        #expect(packet[0] == 0x31 && packet[1] == 0x02)
        #expect(Array(packet.suffix(4)) == [0x26, 0xa1, 0xe7, 0xf7])
        let crc = DualSenseReport.crc32([0xa2] + Array(packet.prefix(74)))
        #expect(Array(packet.suffix(4)) == (0..<4).map { UInt8(truncatingIfNeeded: crc >> ($0 * 8)) })
    }
    @Test func onlyRumbleTakesTheControllerOutOfSoundHaptics() {
        var rumble = DualSenseReport(); rumble.rumble(left: 0, right: 0)
        #expect(rumble.selectsRumble)
        #expect(rumble.packet(bluetooth: false)[1] & 0x03 == 0x03)
        var other = DualSenseReport()
        #expect(!other.selectsRumble)
        other.triggers(left: [UInt8](repeating: 0, count: 11), right: [UInt8](repeating: 0, count: 11))
        other.led(red: 1, green: 2, blue: 3); other.player(1)
        #expect(!other.selectsRumble)
        #expect(other.packet(bluetooth: false)[1] & 0x03 == 0)
    }
    @Test func theLightBarIsNeverLeftDark() {
        var asked = DualSenseReport(); asked.light(red: 200, green: 10, blue: 30)
        #expect(asked.effects[1] & 0x04 != 0)
        #expect(Array(asked.packet(bluetooth: false)[45...47]) == [200, 10, 30])
        var black = DualSenseReport(); black.light(red: 0, green: 0, blue: 0)
        #expect(black.effects[1] & 0x04 != 0)
        let shown = Array(black.packet(bluetooth: false)[45...47])
        #expect(shown == [DualSenseReport.ownLight.red, DualSenseReport.ownLight.green, DualSenseReport.ownLight.blue])
        #expect(shown.contains { $0 > 0 })
    }
    @Test func malformedEffectDoesNotEnableTriggers() {
        var report = DualSenseReport()
        report.triggers(left: [], right: [0x05])
        #expect(report.effects[0] == 0)
    }
}
