import XCTest
import SoleCore
import SoleEngine
@testable import SoleLogic

final class ControlsTests: XCTestCase {
    private func reading(_ buttons: ControllerState.Button = [], leftX: Float = 0, leftY: Float = 0) -> PadReading {
        var reading = PadReading(); reading.buttons = buttons; reading.leftX = leftX; reading.leftY = leftY
        return reading
    }

    func testKeysAreNamedAsTheyArePrinted() {
        XCTAssertEqual(Key.name(Key.a), "A"); XCTAssertEqual(Key.name(Key.w), "W"); XCTAssertEqual(Key.name(Key.z), "Z")
        XCTAssertEqual(Key.name(Key.one), "1"); XCTAssertEqual(Key.name(Key.one + 8), "9"); XCTAssertEqual(Key.name(Key.zero), "0")
        XCTAssertEqual(Key.name(Key.f1), "F1"); XCTAssertEqual(Key.name(Key.f12), "F12")
        XCTAssertEqual(Key.name(Key.up), "↑"); XCTAssertEqual(Key.name(Key.left), "←")
        XCTAssertEqual(Key.name(Key.escape), "Esc"); XCTAssertEqual(Key.name(Key.space), "Space")
        XCTAssertEqual(Key.name(Key.leftShift), "Left Shift"); XCTAssertEqual(Key.name(Key.rightControl), "Right Control")
        #if os(macOS)
        XCTAssertEqual(Key.name(Key.enter), "Return"); XCTAssertEqual(Key.name(Key.backspace), "Delete"); XCTAssertEqual(Key.name(Key.leftAlt), "Left Option")
        XCTAssertEqual(Key.name(Key.delete), "Fn Delete")
        #else
        XCTAssertEqual(Key.name(Key.enter), "Enter"); XCTAssertEqual(Key.name(Key.backspace), "Backspace"); XCTAssertEqual(Key.name(Key.leftAlt), "Left Alt")
        XCTAssertEqual(Key.name(Key.delete), "Delete")
        #endif
        XCTAssertEqual(Key.name(0x90), "key 144", "An unnamed key still gets a distinct label")
    }

    func testEveryKeyOfTheStandardLayoutHasAName() {
        for (control, key) in KeyboardLayout.standard.keys {
            XCTAssertFalse(Key.name(key).hasPrefix("key "), "\(control) is on a key without a name")
        }
    }

    func testEveryControlIsListedOnceAndHasItsOwnTitle() {
        let listed = PadControl.groups.flatMap(\.controls)
        XCTAssertEqual(listed.count, PadControl.allCases.count)
        XCTAssertEqual(Set(listed), Set(PadControl.allCases))
        XCTAssertEqual(Set(PadControl.allCases.map(\.title)).count, PadControl.allCases.count)
        XCTAssertEqual(Set(PadControl.groups.map(\.title)).count, PadControl.groups.count)
    }

    func testTheLayoutIsKeptAndReadBack() {
        let defaults = testSettings()
        XCTAssertEqual(KeyboardLayout.stored(in: defaults), .standard)
        XCTAssertNil(defaults.object(forKey: KeyboardLayout.storageKey), "Reading writes nothing")
        var layout = KeyboardLayout.standard
        layout.assign(Key.enter, to: .cross)
        layout.store(in: defaults)
        XCTAssertEqual(KeyboardLayout.stored(in: defaults), layout)
        XCTAssertEqual(KeyboardLayout.stored(in: defaults).keys[.cross], Key.enter)
    }

    func testTheMouseIsAsTheSettingsHaveIt() {
        let fresh = MouseSettings(defaults: testSettings())
        XCTAssertTrue(fresh.enabled); XCTAssertEqual(fresh.sensitivity, 5); XCTAssertFalse(fresh.bumpers)
        let set = MouseSettings(defaults: testSettings([MouseSettings.enabledKey: false, MouseSettings.sensitivityKey: 8.0, MouseSettings.buttonsKey: "bumpers"]))
        XCTAssertFalse(set.enabled); XCTAssertEqual(set.sensitivity, 8); XCTAssertTrue(set.bumpers)
        XCTAssertEqual(MouseSettings.buttonChoices.map(\.value), ["triggers", "bumpers"])
        XCTAssertTrue(MouseSettings.sensitivities.contains(MouseSettings.standardSensitivity))
    }

    func testTheGamepadAsksTheLibraryForOneDirectionAtATime() {
        XCTAssertEqual(reading().libraryActions, [])
        XCTAssertEqual(reading(leftX: 0.5).libraryActions, [], "A stick pushed less than halfway asks for nothing")
        XCTAssertEqual(reading(leftX: 0.6).libraryActions, [.right])
        XCTAssertEqual(reading(leftX: -0.9, leftY: 0.3).libraryActions, [.left], "The stronger of the two directions counts")
        XCTAssertEqual(reading(leftX: 0.3, leftY: -0.9).libraryActions, [.down])
        XCTAssertEqual(reading(leftY: 1).libraryActions, [.up])
        XCTAssertEqual(reading([.dpadLeft], leftX: 1).libraryActions, [.left], "The D-pad wins over the stick")
        XCTAssertEqual(reading([.dpadUp]).libraryActions, [.up])
        XCTAssertEqual(reading([.dpadDown, .dpadRight]).libraryActions, [.down], "A D-pad corner is still one direction")
    }

    func testTheButtonsOfTheGamepadInTheLibrary() {
        XCTAssertEqual(reading([.cross]).libraryActions, [.play])
        XCTAssertEqual(reading([.circle]).libraryActions, [.back])
        XCTAssertEqual(reading([.triangle]).libraryActions, [.favorite])
        XCTAssertEqual(reading([.square]).libraryActions, [.erase])
        XCTAssertEqual(reading([.options]).libraryActions, [.settings])
        XCTAssertEqual(reading([.cross, .dpadRight, .l1, .ps]).libraryActions, [.play, .right], "The other buttons ask the library for nothing")
    }

    func testTheCheckOfAGamepadNamesWhatIsHeld() {
        XCTAssertEqual(PadReading().held, [])
        XCTAssertEqual(PadReading().heldText, "Press a button or move a stick")
        var pad = reading([.cross, .triangle, .r1, .dpadLeft], leftX: 0.3)
        pad.r2 = 0.5; pad.l2 = 0.05; pad.rightY = -0.1
        XCTAssertEqual(pad.held, ["A / ×", "Y / △", "R1", "R2", "←", "Left stick"])
        XCTAssertEqual(pad.heldText, "A / × · Y / △ · R1 · R2 · ← · Left stick")
        pad.rightY = -0.5
        XCTAssertEqual(pad.held.last, "Right stick")
    }

    func testAReadingJoinsTheKeyboardAsItsPartsDid() {
        var pad = reading([.square], leftX: 0.3, leftY: -0.2); pad.l2 = 0.5; pad.r2 = 0.25; pad.rightX = 0.4
        var keyboard = PadReading(); keyboard.buttons = [.cross]; keyboard.r2 = 1; keyboard.leftY = 1
        var whole = ControllerState(), parts = ControllerState()
        whole.merge(keyboard, pad: pad)
        parts.merge(keyboard, buttons: [.square], l2: 0.5, r2: 0.25, leftX: 0.3, leftY: -0.2, rightX: 0.4, rightY: 0)
        XCTAssertEqual(whole.raw.buttons, parts.raw.buttons)
        XCTAssertEqual(whole.raw.l2, parts.raw.l2); XCTAssertEqual(whole.raw.r2, parts.raw.r2)
        XCTAssertEqual(whole.raw.leftX, parts.raw.leftX); XCTAssertEqual(whole.raw.leftY, parts.raw.leftY)
        XCTAssertEqual(whole.raw.rightX, parts.raw.rightX); XCTAssertEqual(whole.raw.rightY, parts.raw.rightY)
    }
}
