import XCTest
import SoleCore
@testable import Sole

final class ControllerKeyboardTests: XCTestCase {
    @MainActor func testTheGamepadTypesIntoTheTextItWasOpenedFor() {
        let focus = ControllerFocus()
        var text = "", ended: [Bool] = []
        focus.selected = "search"
        focus.openKeyboard(text: "", write: { text = $0 }, closed: { ended.append($0) })
        XCTAssertNotNil(focus.keyboard)
        XCTAssertTrue(focus.handle(.play))
        XCTAssertTrue(focus.handle(.right)); _ = focus.handle(.play)
        _ = focus.handle(.favorite)
        _ = focus.handle(.play)
        XCTAssertEqual(text, "qw w")
        _ = focus.handle(.erase)
        XCTAssertEqual(text, "qw ")
        XCTAssertEqual(focus.selected, "search", "The field keeps focus while text is typed")
        _ = focus.handle(.settings)
        XCTAssertNil(focus.keyboard)
        XCTAssertEqual(ended, [true])
        focus.openKeyboard(text: text, write: { text = $0 }, closed: { ended.append($0) })
        _ = focus.handle(.play)
        XCTAssertEqual(text, "qw q")
        _ = focus.handle(.back)
        XCTAssertNil(focus.keyboard)
        XCTAssertEqual(ended, [true, false])
        XCTAssertEqual(text, "qw q")
        focus.openKeyboard(text: "", write: { text = $0 })
        focus.pointKey(.character("m"))
        XCTAssertEqual(focus.keyboard?.selected, .character("m"))
        focus.pressKey(.character("z"))
        XCTAssertEqual(text, "z")
        focus.pressKey(.done)
        XCTAssertNil(focus.keyboard)
    }
}
