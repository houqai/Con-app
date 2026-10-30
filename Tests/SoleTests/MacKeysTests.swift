import AppKit
import XCTest
import SoleEngine
import SoleLogic
@testable import Sole

final class MacKeysTests: XCTestCase {
    private let formerStandard: [String: Int] = [
        "leftUp": 13, "leftLeft": 0, "leftDown": 1, "leftRight": 2, "walk": 58,
        "rightUp": 126, "rightLeft": 123, "rightDown": 125, "rightRight": 124,
        "cross": 49, "circle": 56, "square": 14, "triangle": 12,
        "l1": 9, "r1": 3, "l2": 8, "r2": 15, "l3": 59, "r3": 60,
        "dpadUp": 34, "dpadLeft": 38, "dpadDown": 40, "dpadRight": 37,
        "options": 53, "share": 16, "touchpad": 17, "ps": 35,
    ]

    func testNoTwoKeysOfAMacShareAPlace() {
        XCTAssertEqual(Set(MacKeys.usages.values).count, MacKeys.usages.count)
        XCTAssertGreaterThan(MacKeys.usages.count, 110)
    }

    func testALayoutKeptInMacOSKeyCodesBecomesTheSameLayout() {
        XCTAssertEqual(formerStandard.count, PadControl.allCases.count)
        XCTAssertEqual(KeyboardLayout(encoded: MacKeys.translated(formerStandard)), .standard)
        var changed = formerStandard
        changed["cross"] = 36; changed["circle"] = 0x7F
        let layout = KeyboardLayout(encoded: MacKeys.translated(changed))
        XCTAssertEqual(layout.keys[.cross], Key.enter)
        XCTAssertEqual(layout.keys[.circle], Key.leftShift, "An unmapped key code leaves the control on its default key")
        XCTAssertEqual(layout.keys[.leftUp], Key.w)
    }

    func testEveryKeyKeepsTheNameItHad() {
        let former: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "−", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
            45: "N", 46: "M", 47: ".", 50: "`", 36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
            56: "Left Shift", 60: "Right Shift", 59: "Left Control", 62: "Right Control", 58: "Left Option", 61: "Right Option",
            123: "←", 124: "→", 125: "↓", 126: "↑", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12", 117: "Fn Delete", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        ]
        for (code, name) in former {
            guard let usage = MacKeys.usages[code] else { XCTFail("macOS key \(code) (\(name)) has no HID usage"); continue }
            XCTAssertEqual(Key.name(usage), name, "macOS key \(code)")
        }
    }

    func testTheModifiersWithASideHaveTheirPlaces() {
        for code in MacKeys.modifierBits.keys { XCTAssertNotNil(MacKeys.usages[code], "modifier \(code)") }
        XCTAssertEqual(MacKeys.usages[56], Key.leftShift); XCTAssertEqual(MacKeys.usages[60], Key.rightShift)
        XCTAssertEqual(MacKeys.usages[58], Key.leftAlt); XCTAssertEqual(MacKeys.usages[59], Key.leftControl)
    }

    @MainActor func testAKeyLetGoWhileCommandIsHeldIsLetGoInTheGame() {
        let input = KeyboardInput()
        let deviceLeftShift: UInt = 0x02
        let command = NSEvent.ModifierFlags.command.rawValue, shift = NSEvent.ModifierFlags.shift.rawValue | deviceLeftShift
        XCTAssertTrue(input.take(.keyDown, key: 13, flags: 0))
        XCTAssertNotEqual(input.sample(), PadReading())
        XCTAssertFalse(input.take(.keyUp, key: 13, flags: command))
        XCTAssertEqual(input.sample(), PadReading(), "W released while ⌘ is held")
        XCTAssertFalse(input.take(.flagsChanged, key: 56, flags: shift))
        let shifted = input.sample()
        XCTAssertNotEqual(shifted, PadReading())
        XCTAssertTrue(input.take(.keyDown, key: 13, flags: shift))
        XCTAssertNotEqual(input.sample(), shifted)
        XCTAssertFalse(input.take(.flagsChanged, key: 55, flags: shift | command))
        XCTAssertEqual(input.sample(), shifted, "Pressing ⌘ releases the keys but keeps the held modifiers")
        XCTAssertFalse(input.take(.keyDown, key: 13, flags: shift | command))
        XCTAssertEqual(input.sample(), shifted)
    }
}
