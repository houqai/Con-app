import XCTest
@testable import SoleCore

final class StreamMenuTests: XCTestCase {
    private let all = StreamMenu.items(generation: true)

    func testThePSButtonOpensAndClosesItOncePerPress() {
        var menu = StreamMenu()
        XCTAssertEqual(menu.take([.toggle], at: 0, items: all), .opened)
        XCTAssertTrue(menu.isOpen)
        XCTAssertEqual(menu.items, [.resume, .stats, .generation, .fullScreen, .leave])
        XCTAssertEqual(menu.selection, 0)
        for step in 1...50 { XCTAssertEqual(menu.take([.toggle], at: Double(step) * 0.008, items: all), .none) }
        XCTAssertTrue(menu.isOpen)
        XCTAssertEqual(menu.take([], at: 0.5, items: all), .none)
        XCTAssertEqual(menu.take([.toggle], at: 0.6, items: all), .closed)
        XCTAssertFalse(menu.isOpen)
        _ = menu.take([], at: 0.7, items: all)
        XCTAssertEqual(menu.take([.toggle], at: 0.8, items: StreamMenu.items(generation: false)), .opened)
        XCTAssertEqual(menu.items, [.resume, .stats, .fullScreen, .leave])
        XCTAssertEqual(StreamMenu.items(generation: false, fullScreen: false), [.resume, .stats, .leave])
        XCTAssertEqual(StreamMenu.items(generation: true, fullScreen: false), [.resume, .stats, .generation, .leave])
        XCTAssertEqual(StreamMenu.items(generation: true, upscaler: true, upscaleMethod: true), [.resume, .stats, .generation, .upscaler, .upscaleAmount, .upscaleMethod, .fullScreen, .leave])
        XCTAssertEqual(StreamMenu.items(generation: false, upscaler: true, fullScreen: false), [.resume, .stats, .upscaler, .upscaleAmount, .leave])
    }

    func testMovesByOneRowPerPressAndGoesOnWhileADirectionIsHeld() {
        var menu = StreamMenu()
        _ = menu.take([.toggle], at: 0, items: all); _ = menu.take([], at: 0.01, items: all)
        _ = menu.take([.down], at: 0.10, items: all)
        XCTAssertEqual(menu.selection, 1)
        _ = menu.take([.down], at: 0.30, items: all)
        XCTAssertEqual(menu.selection, 1, "Held, and not yet long enough")
        _ = menu.take([.down], at: 0.49, items: all)
        XCTAssertEqual(menu.selection, 2, "After the pause")
        _ = menu.take([.down], at: 0.55, items: all)
        XCTAssertEqual(menu.selection, 2)
        _ = menu.take([.down], at: 0.64, items: all)
        XCTAssertEqual(menu.selection, 3, "Then faster")
        for step in 0..<20 { _ = menu.take([.down], at: 0.8 + Double(step) * 0.15, items: all) }
        XCTAssertEqual(menu.selection, 4, "The last row is the end")
        _ = menu.take([], at: 5, items: all)
        for step in 0..<9 { _ = menu.take(step % 2 == 0 ? [.up] : [], at: 6 + Double(step) * 0.05, items: all) }
        XCTAssertEqual(menu.selection, 0, "And the first row the beginning")
        _ = menu.take([], at: 7, items: all); _ = menu.take([.up, .down], at: 7.1, items: all)
        XCTAssertEqual(menu.selection, 0)
    }

    func testChoosesTheRowUnderTheSelectionAndGoesBack() {
        var menu = StreamMenu()
        XCTAssertEqual(menu.take([.select], at: 0, items: all), .none, "Closed: the game's own button")
        _ = menu.take([], at: 0.1, items: all)
        _ = menu.take([.toggle], at: 0.2, items: all); _ = menu.take([], at: 0.3, items: all)
        XCTAssertEqual(menu.take([.select], at: 0.4, items: all), .chosen(.resume))
        XCTAssertEqual(menu.take([.select], at: 0.5, items: all), .none, "Once per press")
        _ = menu.take([], at: 0.6, items: all); _ = menu.take([.down], at: 0.7, items: all); _ = menu.take([], at: 0.8, items: all)
        XCTAssertEqual(menu.take([.select], at: 0.9, items: all), .chosen(.stats))
        XCTAssertTrue(menu.isOpen, "A row that switches something leaves the menu open")
        menu.select(.leave)
        _ = menu.take([], at: 1, items: all)
        XCTAssertEqual(menu.take([.select], at: 1.1, items: all), .chosen(.leave), "The row the pointer is over")
        _ = menu.take([], at: 1.2, items: all)
        XCTAssertEqual(menu.take([.back], at: 1.3, items: all), .closed)
        XCTAssertEqual(menu.take([.back], at: 1.4, items: all), .none)
    }

    func testOnScreenItIsTheSameUnlessWhatIsShownChanges() {
        var menu = StreamMenu(), other = StreamMenu()
        _ = menu.take([.down], at: 0, items: all)
        XCTAssertEqual(menu, other, "Held controls are bookkeeping, not appearance")
        _ = menu.take([.down, .toggle], at: 1, items: all)
        XCTAssertNotEqual(menu, other)
        other.open(items: all)
        XCTAssertEqual(menu, other)
    }
}
