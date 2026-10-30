import Testing
@testable import SoleEngine

@Suite struct KeyboardLayoutTests {
    @Test func nothingPressedIsAnIdlePad() {
        #expect(KeyboardLayout.standard.pad(pressed: []) == PadReading())
        #expect(KeyboardLayout.standard.pad(pressed: [0x90, 0x91]) == PadReading())
    }
    @Test func movementKeysPushTheLeftStick() {
        let layout = KeyboardLayout.standard
        var pad = layout.pad(pressed: [Key.w])
        #expect(pad.leftX == 0 && pad.leftY == 1)
        pad = layout.pad(pressed: [Key.s, Key.a])
        #expect(abs(pad.leftX + 0.7071) < 0.001 && abs(pad.leftY + 0.7071) < 0.001, "a corner is no further than straight")
        pad = layout.pad(pressed: [Key.a, Key.d, Key.w])
        #expect(pad.leftX == 0 && pad.leftY == 1, "opposite keys cancel")
        pad = layout.pad(pressed: [Key.w, Key.leftAlt])
        #expect(pad.leftY == 0.5)
        pad = layout.pad(pressed: [Key.up, Key.right])
        #expect(pad.rightX > 0.7 && pad.rightY > 0.7 && pad.leftX == 0 && pad.leftY == 0)
    }
    @Test func keysPressButtonsAndTriggers() {
        let pad = KeyboardLayout.standard.pad(pressed: [Key.space, Key.leftShift, Key.r, Key.i, Key.escape])
        #expect(pad.buttons == [.cross, .circle, .dpadUp, .options])
        #expect(pad.r2 == 1 && pad.l2 == 0)
    }
    @Test func everyControlHasItsOwnKey() {
        let keys = KeyboardLayout.standard.keys
        #expect(keys.count == PadControl.allCases.count)
        #expect(Set(keys.values).count == keys.count)
    }
    @Test func assigningATakenKeySwapsTheTwo() {
        var layout = KeyboardLayout.standard
        layout.assign(Key.space, to: .circle)
        #expect(layout.keys[.circle] == Key.space && layout.keys[.cross] == Key.leftShift)
        #expect(Set(layout.keys.values).count == layout.keys.count)
        layout.assign(100, to: .circle)
        #expect(layout.keys[.circle] == 100 && layout.keys[.cross] == Key.leftShift)
        layout.assign(100, to: .circle)
        #expect(layout.keys[.circle] == 100)
    }
    @Test func storedFormRestoresAndIgnoresWhatItDoesNotKnow() {
        var layout = KeyboardLayout.standard
        layout.assign(Key.enter, to: .cross)
        #expect(KeyboardLayout(encoded: layout.encoded) == layout)
        let partial = KeyboardLayout(encoded: ["cross": Int(Key.enter), "noSuchControl": 1, "circle": -5])
        #expect(partial.keys[.cross] == Key.enter && partial.keys[.circle] == Key.leftShift && partial.keys.count == PadControl.allCases.count)
    }
    @Test func keyboardAddsToTheGamepad() {
        var state = ControllerState()
        var keyboard = PadReading(); keyboard.buttons = [.cross]; keyboard.r2 = 1; keyboard.leftY = 1
        state.merge(keyboard, buttons: [.square], l2: 0.5, r2: 0.25, leftX: 0.3, leftY: -0.2, rightX: 0.4, rightY: 0)
        #expect(ControllerState.Button(rawValue: state.raw.buttons) == [.cross, .square])
        #expect(state.raw.l2 == 127 && state.raw.r2 == 255)
        #expect(state.raw.leftX == 0 && state.raw.leftY == -32767, "keys take the stick they push; up is negative for the console")
        #expect(state.raw.rightX > 13000, "the other stick stays with the gamepad")
    }
}
