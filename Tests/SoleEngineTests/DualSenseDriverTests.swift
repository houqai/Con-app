import XCTest
@testable import SoleEngine

final class DualSenseDriverTests: XCTestCase {
    private let slack: [UInt8] = [0x05] + [UInt8](repeating: 0, count: 10)
    private func rumble(_ left: UInt8, _ right: UInt8) -> DualSenseReport { var report = DualSenseReport(); report.rumble(left: left, right: right); return report }
    private func haptics(left: Int16, right: Int16, frames: Int = 30) -> Data {
        var data = Data()
        for _ in 0..<frames { for sample in [left, right] { data.append(UInt8(truncatingIfNeeded: sample)); data.append(UInt8(truncatingIfNeeded: sample >> 8)) } }
        return data
    }

    func testNothingIsWrittenUntilAGamepadIsInUseButWhatIsToShowIsKept() {
        var driver = DualSenseDriver()
        driver.beginSession()
        var light = DualSenseReport(); light.light(red: 9, green: 8, blue: 7)
        XCTAssertNil(driver.send(light, now: 1))
        var player = DualSenseReport(); player.player(2)
        XCTAssertNil(driver.send(player, now: 2))
        let left: [UInt8] = [0x21, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10], right: [UInt8] = [0x26, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1]
        var triggers = DualSenseReport(); triggers.triggers(left: left, right: right)
        XCTAssertNil(driver.send(triggers, now: 3))
        XCTAssertNil(driver.send(rumble(200, 100), now: 4))
        XCTAssertNil(driver.silence()); XCTAssertFalse(driver.playsHaptics)
        driver.start()
        let greeting = driver.greeting()
        XCTAssertEqual(greeting.count, 2)
        XCTAssertEqual(greeting[0].effects[1], 0x08); XCTAssertEqual(greeting[0].effects[0], 0)
        let kept = greeting[1].effects
        XCTAssertEqual(Array(kept[44...46]), [9, 8, 7])
        XCTAssertEqual(kept[1] & 0x14, 0x14); XCTAssertEqual(kept[43], 0x0a)
        XCTAssertEqual(Array(kept[10..<21]), right); XCTAssertEqual(Array(kept[21..<32]), left)
        XCTAssertEqual(kept[0] & 0x03, 0); XCTAssertEqual(kept[2], 0); XCTAssertEqual(kept[3], 0)
    }

    func testANewStreamKeepsNothingOfTheOneBeforeAndLightsTheGamepad() {
        var driver = DualSenseDriver()
        var light = DualSenseReport(); light.light(red: 9, green: 8, blue: 7)
        _ = driver.send(light, now: 1)
        _ = driver.intensity(trigger: true, value: 0)
        driver.beginSession()
        let kept = driver.greeting()[1].effects
        XCTAssertEqual(Array(kept[44...46]), [DualSenseReport.ownLight.red, DualSenseReport.ownLight.green, DualSenseReport.ownLight.blue])
        XCTAssertEqual(driver.outgoing(DualSenseReport()).effects[36], 0, "The strengths start over")
    }

    func testEveryReportCarriesTheStrengthsTheConsoleAskedFor() {
        var driver = DualSenseDriver()
        driver.start()
        XCTAssertEqual(driver.outgoing(DualSenseReport()).effects[1] & 0x40, 0x40)
        XCTAssertEqual(driver.outgoing(DualSenseReport()).effects[36], 0)
        let change = driver.intensity(trigger: true, value: 2)
        XCTAssertNotNil(change.report); XCTAssertFalse(change.stopsHaptics)
        _ = driver.intensity(trigger: false, value: 3)
        XCTAssertEqual(driver.outgoing(DualSenseReport()).effects[36], 0x60 | 3)
        _ = driver.intensity(trigger: false, value: 1)
        XCTAssertEqual(driver.outgoing(DualSenseReport()).effects[36], 0x60)
        _ = driver.intensity(trigger: true, value: 7)
        XCTAssertEqual(driver.outgoing(DualSenseReport()).effects[36], 0, "A value nobody knows is full strength")
    }

    func testTriggersTurnedOffByThePlayerStaySlackWhateverTheGameSends() {
        var driver = DualSenseDriver()
        driver.start()
        let change = driver.intensity(trigger: true, value: 0)
        XCTAssertEqual(change.report.map { Array($0.effects[10..<21]) }, slack, "They go slack at once")
        XCTAssertEqual(change.report.map { Array($0.effects[21..<32]) }, slack)
        let hard = [UInt8](repeating: 0x21, count: 11)
        var triggers = DualSenseReport(); triggers.triggers(left: hard, right: hard)
        let sent = driver.send(triggers, now: 1)
        XCTAssertEqual(sent.map { Array($0.effects[10..<21]) }, hard, "The game's report is kept as it came")
        let written = driver.outgoing(sent!)
        XCTAssertEqual(Array(written.effects[10..<21]), slack); XCTAssertEqual(Array(written.effects[21..<32]), slack)
        XCTAssertEqual(written.effects[36], 0xf0)
        XCTAssertEqual(Array(driver.outgoing(rumble(1, 1)).effects[10..<21]), [UInt8](repeating: 0, count: 11), "A report that is not about triggers is not made one")
        _ = driver.intensity(trigger: true, value: 1)
        XCTAssertEqual(Array(driver.outgoing(sent!).effects[10..<21]), hard, "Turned on again, they get what the game sends")
    }

    func testVibrationTurnedOffByThePlayerStopsTheMotorsAndTheSound() {
        var driver = DualSenseDriver()
        driver.start()
        XCTAssertTrue(driver.playsHaptics)
        let off = driver.intensity(trigger: false, value: 0)
        XCTAssertTrue(off.stopsHaptics)
        XCTAssertEqual(off.report?.effects[0], 0x03); XCTAssertEqual(off.report?.effects[2], 0); XCTAssertEqual(off.report?.effects[3], 0)
        XCTAssertFalse(driver.playsHaptics)
        XCTAssertEqual(driver.outgoing(DualSenseReport()).effects[36], 0x0f)
        XCTAssertFalse(driver.intensity(trigger: false, value: 2).stopsHaptics)
        XCTAssertTrue(driver.playsHaptics)
        var idle = DualSenseDriver()
        let unused = idle.intensity(trigger: false, value: 0)
        XCTAssertTrue(unused.stopsHaptics); XCTAssertNil(unused.report)
    }

    func testAfterRumbleOneEmptyReportReturnsTheGamepadToSoundHaptics() {
        var driver = DualSenseDriver()
        driver.start()
        XCTAssertNotNil(driver.returnToHaptics, "Until something was written the gamepad may be in rumble")
        let empty = driver.outgoing(driver.returnToHaptics!)
        XCTAssertEqual(empty.effects[0] & 0x03, 0)
        driver.wrote(empty, succeeded: true)
        XCTAssertNil(driver.returnToHaptics, "Once is enough: not with every frame")
        var light = DualSenseReport(); light.light(red: 1, green: 2, blue: 3)
        driver.wrote(driver.outgoing(light), succeeded: true)
        XCTAssertNil(driver.returnToHaptics, "A light does not touch the motors")
        driver.wrote(driver.outgoing(rumble(0, 0)), succeeded: true)
        XCTAssertNotNil(driver.returnToHaptics, "Any rumble, a stopping one too, takes the gamepad out of sound haptics")
        driver.wrote(empty, succeeded: true)
        driver.wrote(empty, succeeded: false)
        XCTAssertNotNil(driver.returnToHaptics, "A gamepad that went away comes back in an unknown state")
    }

    func testWithoutSoundChannelsTheMotorsPlayTheStrengthOfTheHaptics() {
        var driver = DualSenseDriver()
        driver.start(); driver.bluetooth = true
        let strong = driver.rumble(for: haptics(left: 16384, right: 4096), now: 1_000_000_000)
        XCTAssertEqual(strong?.effects[0], 0x03)
        XCTAssertEqual(strong?.effects[3], 127); XCTAssertEqual(strong?.effects[2], 31)
        XCTAssertNil(driver.rumble(for: haptics(left: 16384, right: 16384), now: 1_010_000_000), "At most sixty times a second")
        XCTAssertNil(driver.rumble(for: Data([1, 2]), now: 2_000_000_000), "Less than a frame is nothing")
        let silent = driver.rumble(for: haptics(left: 0, right: 0), now: 1_020_000_000)
        XCTAssertEqual(silent?.effects[2], 0); XCTAssertEqual(silent?.effects[3], 0)
        XCTAssertEqual(driver.rumble(for: haptics(left: -32768, right: 32767), now: 3_000_000_000)?.effects[3], 127, "Loudness, not direction")
    }

    func testARumbleLastsItsLengthUnlessAnotherFollows() {
        var driver = DualSenseDriver()
        driver.start()
        _ = driver.rumble(for: haptics(left: 9000, right: 9000), now: 1_000_000_000)
        let first = driver.lastRumble
        XCTAssertEqual(driver.rest(afterRumbleAt: first)?.effects[0], 0x03, "Nothing followed: the motors stop")
        _ = driver.rumble(for: haptics(left: 9000, right: 9000), now: 1_050_000_000)
        XCTAssertNil(driver.rest(afterRumbleAt: first), "Another rumble is going on")
        _ = driver.send(rumble(50, 50), now: 1_060_000_000)
        XCTAssertNil(driver.rest(afterRumbleAt: 1_050_000_000))
        XCTAssertNil(driver.rumble(for: haptics(left: 9000, right: 9000), now: 1_065_000_000), "And holds the next one back as its own would")
        XCTAssertEqual(DualSenseDriver.rumbleLength, 0.08)
    }

    func testAGamepadLetGoStopsShakingAndItsTriggersGoSlack() {
        var driver = DualSenseDriver()
        driver.start()
        XCTAssertEqual(driver.silence()?.effects[0], 0x03, "Only the motors")
        let last = driver.stop()
        XCTAssertEqual(last.effects[0], 0x0f)
        XCTAssertEqual(Array(last.effects[10..<21]), slack); XCTAssertEqual(Array(last.effects[21..<32]), slack)
        XCTAssertFalse(driver.active); XCTAssertNil(driver.silence())
        XCTAssertNil(driver.send(rumble(1, 1), now: 1)); XCTAssertNil(driver.rest(afterRumbleAt: driver.lastRumble))
    }
}
