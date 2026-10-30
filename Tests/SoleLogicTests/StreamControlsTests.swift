import XCTest
import SoleCore
import SoleEngine
@testable import SoleLogic

final class StreamControlsTests: XCTestCase {
    func testReadsItsControlsFromTheStateTheGameWouldGet() {
        func input(_ buttons: ControllerState.Button = [], leftY: Float = 0, rightY: Float = 0) -> StreamMenu.Input {
            var state = ControllerState()
            state.setButtons(buttons); state.setSticks(leftX: 0, leftY: leftY, rightX: 0, rightY: rightY)
            return StreamMenu.input(from: state)
        }
        XCTAssertEqual(input(), [])
        XCTAssertEqual(input(.ps), [.toggle])
        XCTAssertEqual(input(.cross), [.select])
        XCTAssertEqual(input(.circle), [.back])
        XCTAssertEqual(input(.options), [.back], "Escape on the keyboard")
        XCTAssertEqual(input(.dpadUp), [.up])
        XCTAssertEqual(input(.dpadDown), [.down])
        XCTAssertEqual(input(leftY: 1), [.up], "A stick pushed away is up")
        XCTAssertEqual(input(leftY: -1), [.down])
        XCTAssertEqual(input(rightY: 1), [.up], "The arrows of the keyboard are the right stick")
        XCTAssertEqual(input(leftY: 0.3), [], "A stick that is only leaning does nothing")
        XCTAssertEqual(input([.square, .l1, .dpadLeft]), [])
    }

    private func reading(_ buttons: ControllerState.Button = [], leftX: Float = 0) -> ControllerState {
        var state = ControllerState()
        state.setButtons(buttons); state.setSticks(leftX: leftX, leftY: 0, rightX: 0, rightY: 0)
        return state
    }
    private func buttons(_ state: ControllerState) -> ControllerState.Button { .init(rawValue: state.raw.buttons) }

    func testTheGameGetsEverythingButThePSButtonWhileTheMenuIsClosed() {
        var controls = StreamControls()
        XCTAssertEqual(controls.take(reading([.cross, .l1], leftX: 1), at: 0, generation: true), .none)
        let game = controls.forGame(reading([.cross, .l1], leftX: 1))
        XCTAssertEqual(buttons(game), [.cross, .l1])
        XCTAssertEqual(game.raw.leftX, 32767)
        XCTAssertFalse(controls.menu.isOpen)
    }

    func testThePSButtonOpensTheMenuAndTheGameGetsNothingWhileItIsOpen() {
        var controls = StreamControls()
        XCTAssertEqual(controls.take(reading(.ps), at: 0, generation: true), .opened)
        XCTAssertTrue(controls.menu.isOpen)
        XCTAssertEqual(controls.menu.items, [.resume, .stats, .generation, .fullScreen, .leave])
        let game = controls.forGame(reading([.ps, .cross], leftX: 1))
        XCTAssertEqual(buttons(game), [])
        XCTAssertEqual(game.raw.leftX, 0, "A stick that is held moves the menu, not the game")
        XCTAssertEqual(buttons(controls.forGame(reading(.ps))), [], "The PS button never reaches the game")
    }

    func testTheMenuOffersGenerationOnlyWhereItCanBeHad() {
        var controls = StreamControls()
        _ = controls.take(reading(.ps), at: 0, generation: false)
        XCTAssertEqual(controls.menu.items, [.resume, .stats, .fullScreen, .leave])
    }

    func testATouchOpensTheMenuWithoutTheFullScreenWhereThereIsNoWindow() {
        var controls = StreamControls()
        controls.openMenu(generation: false, fullScreen: false)
        XCTAssertTrue(controls.menu.isOpen)
        XCTAssertEqual(controls.menu.items, [.resume, .stats, .leave])
        XCTAssertEqual(buttons(controls.forGame(reading(.cross))), [], "While the menu is open the game gets nothing")
        _ = controls.take(reading(), at: 0, generation: false, fullScreen: false)
        XCTAssertEqual(controls.take(reading(.ps), at: 0.1, generation: false, fullScreen: false), .closed, "The PS button closes what a touch opened")
    }

    func testTheMenuOffersTheRestartFirstAndAnOpenMenuGetsIt() {
        XCTAssertEqual(StreamMenu.items(generation: false, fullScreen: false, restart: true), [.restart, .resume, .stats, .leave])
        var controls = StreamControls()
        controls.openMenu(generation: false, fullScreen: false)
        XCTAssertEqual(controls.menu.items, [.resume, .stats, .leave])
        controls.openMenu(generation: false, fullScreen: false, restart: true)
        XCTAssertEqual(controls.menu.items.first, .restart)
        XCTAssertEqual(controls.menu.selection, 0, "The restart is chosen")
        XCTAssertEqual(StreamMenu.Item.restart.title(fullScreen: false), loc("Restart game"))
    }

    func testAButtonThatClosedTheMenuDoesNotReachTheGameUntilItIsLetGo() {
        var controls = StreamControls()
        _ = controls.take(reading(.ps), at: 0, generation: true)
        _ = controls.take(reading(), at: 0.1, generation: true)
        XCTAssertEqual(controls.take(reading(.circle), at: 0.2, generation: true), .closed)
        XCTAssertEqual(buttons(controls.forGame(reading(.circle))), [], "○ closed the menu: the game must not take it as a press")
        _ = controls.take(reading([.circle, .cross]), at: 0.3, generation: true)
        XCTAssertEqual(buttons(controls.forGame(reading([.circle, .cross]))), [.cross], "A button pressed after the menu closed is the game's")
        _ = controls.take(reading(), at: 0.4, generation: true)
        _ = controls.forGame(reading())
        _ = controls.take(reading(.circle), at: 0.5, generation: true)
        XCTAssertEqual(buttons(controls.forGame(reading(.circle))), [.circle], "Let go and pressed again, it is a press")
    }

    func testARowChosenInTheMenuIsReportedAndClosingFromOutsideSwallowsWhatIsHeld() {
        var controls = StreamControls()
        _ = controls.take(reading(.ps), at: 0, generation: true)
        _ = controls.take(reading(), at: 0.1, generation: true)
        XCTAssertEqual(controls.take(reading(.cross), at: 0.2, generation: true), .chosen(.resume))
        XCTAssertTrue(controls.menu.isOpen, "The row is the app's to act on")
        controls.closeMenu(holding: [.cross])
        XCTAssertFalse(controls.menu.isOpen)
        XCTAssertEqual(buttons(controls.forGame(reading(.cross))), [])
    }

    func testThePointerMovesTheChoiceAndTheEndOfAStreamClosesTheMenu() {
        var controls = StreamControls()
        _ = controls.take(reading(.ps), at: 0, generation: true)
        controls.point(at: .leave)
        XCTAssertEqual(controls.menu.items[controls.menu.selection], .leave)
        controls.reset()
        XCTAssertFalse(controls.menu.isOpen)
        XCTAssertEqual(buttons(controls.forGame(reading(.ps))), [])
    }

    func testAFingerKeepsItsNumberWhileItIsDownAndTheNextTakesTheNext() {
        var touches = TouchSlots()
        XCTAssertNil(touches.id(slot: 0, present: false))
        XCTAssertEqual(touches.id(slot: 0, present: true), 0)
        XCTAssertEqual(touches.id(slot: 0, present: true), 0)
        XCTAssertEqual(touches.id(slot: 1, present: true), 1)
        XCTAssertNil(touches.id(slot: 0, present: false))
        XCTAssertEqual(touches.id(slot: 0, present: true), 2)
        touches.lift()
        XCTAssertEqual(touches.id(slot: 1, present: true), 3, "Another gamepad: the count goes on")
        XCTAssertNil(touches.id(slot: 2, present: true), "A touchpad has two fingers")
        for _ in 0..<130 { _ = touches.id(slot: 0, present: false); _ = touches.id(slot: 0, present: true) }
        XCTAssertTrue((0...127).contains(touches.id(slot: 0, present: true) ?? -1), "The numbers wrap at 127")
    }
}
