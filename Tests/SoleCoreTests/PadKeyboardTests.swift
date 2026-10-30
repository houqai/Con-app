import XCTest
@testable import SoleCore

final class PadKeyboardTests: XCTestCase {
    private func characters(_ keyboard: PadKeyboard) -> String {
        String(keyboard.rows.joined().compactMap { key -> Character? in if case .character(let c) = key { return c } else { return nil } })
    }

    func testHasEveryEnglishLetterAndDigitOnceAndTheKeysThatAreNotLetters() {
        let keyboard = PadKeyboard()
        XCTAssertEqual(Set(characters(keyboard)).intersection(Set("abcdefghijklmnopqrstuvwxyz0123456789")).count, 36)
        XCTAssertEqual(characters(keyboard).count, Set(characters(keyboard)).count, "No key twice")
        XCTAssertTrue(characters(keyboard).allSatisfy(\.isASCII), "English letters only")
        XCTAssertEqual(keyboard.rows.last, [.space, .erase, .done])
        let widths = keyboard.rows.map { $0.reduce(0) { $0 + keyboard.span($1) } }
        XCTAssertEqual(Set(widths), [10], "\(widths)")
        XCTAssertEqual(keyboard.selected, .character("q"), "It opens on the first letter")
    }

    func testTheCursorGoesRoundARowAndToTheKeyAboveOrBelow() {
        var keyboard = PadKeyboard()
        keyboard.move(.left)
        XCTAssertEqual(keyboard.selected, .character("p"), "Round the end of the row")
        keyboard.move(.right)
        XCTAssertEqual(keyboard.selected, .character("q"))
        keyboard.move(.up)
        XCTAssertEqual(keyboard.selected, .character("1"))
        keyboard.move(.up)
        XCTAssertEqual(keyboard.selected, .character("1"), "The first row is the top")
        for _ in 0..<4 { keyboard.move(.right) }
        XCTAssertEqual(keyboard.selected, .character("5"))
        for letter in ["t", "g", "b"] { keyboard.move(.down); XCTAssertEqual(keyboard.selected, .character(Character(letter))) }
        keyboard.move(.down)
        XCTAssertEqual(keyboard.selected, .space, "The long key lies under the middle of the letters")
        keyboard.move(.down)
        XCTAssertEqual(keyboard.selected, .space, "The last row is the bottom")
        keyboard.move(.right); XCTAssertEqual(keyboard.selected, .erase)
        keyboard.move(.right); XCTAssertEqual(keyboard.selected, .done)
        keyboard.move(.right); XCTAssertEqual(keyboard.selected, .space, "Round the bottom row as well")
        keyboard.select(.done)
        keyboard.move(.up)
        XCTAssertTrue([PadKeyboard.Key.character(":"), .character("&")].contains(keyboard.selected), "Straight up from the key: \(keyboard.selected)")
        keyboard.select(.character("z"))
        keyboard.move(.down)
        XCTAssertEqual(keyboard.selected, .space)
        keyboard.move(.up)
        XCTAssertTrue("xcvb".map(PadKeyboard.Key.character).contains(keyboard.selected), "Up from the long key, to a letter over its middle: \(keyboard.selected)")
    }

    func testKeysTypeAndErase() {
        let keyboard = PadKeyboard()
        var text = ""
        for letter in "god" { XCTAssertFalse(keyboard.press(.character(letter), on: &text)) }
        XCTAssertFalse(keyboard.press(.space, on: &text)); XCTAssertFalse(keyboard.press(.space, on: &text))
        XCTAssertEqual(text, "god ", "One space at a time")
        _ = keyboard.press(.character("o"), on: &text); _ = keyboard.press(.character("f"), on: &text)
        XCTAssertEqual(text, "god of")
        _ = keyboard.press(.erase, on: &text)
        XCTAssertEqual(text, "god o")
        XCTAssertTrue(keyboard.press(.done, on: &text), "Typing is over")
        XCTAssertEqual(text, "god o")
        var empty = ""
        _ = keyboard.press(.erase, on: &empty); _ = keyboard.press(.space, on: &empty)
        XCTAssertEqual(empty, "", "Nothing to erase, and no text begins with a space")
        var long = String(repeating: "a", count: PadKeyboard.limit)
        _ = keyboard.press(.character("b"), on: &long); _ = keyboard.press(.space, on: &long)
        XCTAssertEqual(long.count, PadKeyboard.limit)
    }
}
