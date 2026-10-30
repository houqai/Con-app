import XCTest
@testable import SoleCore

final class FocusGeometryTests: XCTestCase {
    private func center(_ x: Double, _ y: Double, _ width: Double = 100, _ height: Double = 60) -> FocusGeometry.Place { (x + width / 2, y + height / 2) }
    private var targets: [(id: String, at: FocusGeometry.Place)] {
        [("search", center(0, 0, 340, 40)), ("game:a", center(0, 100)), ("game:b", center(120, 100)), ("game:c", center(240, 100)),
         ("game:d", center(0, 180)), ("game:e", center(120, 180)), ("game:f", center(240, 180))]
    }
    private func next(from id: String, _ direction: FocusGeometry.Direction) -> String? {
        let current = targets.first { $0.id == id }!.at
        return FocusGeometry.next(from: current, to: direction, among: targets.filter { $0.id != id })
    }

    func testTheFrameGoesToTheNearestThingStraightAhead() {
        XCTAssertEqual(next(from: "game:a", .right), "game:b")
        XCTAssertEqual(next(from: "game:b", .right), "game:c")
        XCTAssertEqual(next(from: "game:b", .down), "game:e")
        XCTAssertEqual(next(from: "game:e", .up), "game:b")
        XCTAssertEqual(next(from: "game:f", .left), "game:e")
    }

    func testNothingLiesPastTheEdge() {
        XCTAssertNil(next(from: "game:c", .right))
        XCTAssertNil(next(from: "game:d", .left))
        XCTAssertNil(next(from: "game:e", .down))
        XCTAssertNil(next(from: "search", .up))
    }

    func testAThingAsideIsReachedWhenNothingIsStraightAheadAndStraightIsPreferred() {
        XCTAssertEqual(next(from: "game:c", .up), "search", "The search field is still the target above, though not directly over the last cover")
        XCTAssertEqual(next(from: "search", .down), "game:b", "The cover below its center")
        XCTAssertEqual(next(from: "game:a", .down), "game:d", "Not the one diagonally below")
    }

    func testAThingThatOnlyJustLiesAheadDoesNotCount() {
        let current = center(0, 0)
        XCTAssertNil(FocusGeometry.next(from: current, to: .right, among: [(id: "near", at: center(8, 0))]), "Eight points ahead is the same place")
        XCTAssertEqual(FocusGeometry.next(from: current, to: .right, among: [(id: "near", at: center(9, 0))]), "near")
        XCTAssertEqual(FocusGeometry.next(from: current, to: .right, among: [(id: "one", at: center(50, 0)), (id: "two", at: center(50, 0))]), "one", "Of two equally near, the earlier")
        XCTAssertNil(FocusGeometry.next(from: current, to: .left, among: [(id: 1, at: center(50, 0))]))
    }

    func testTheFrameStartsOnAGame() {
        XCTAssertEqual(FocusGeometry.first(of: ["search", "filter:all", "game:a", "game:b"]), "game:a")
        XCTAssertEqual(FocusGeometry.first(of: ["settings:close", "quality:1080"]), "settings:close")
        XCTAssertNil(FocusGeometry.first(of: []))
    }
}

final class FocusModelTests: XCTestCase {
    @MainActor func testTheFrameStartsOnAGameThenFollowsThePressesAndPressesWhatItStandsOn() async {
        let focus = FocusModel()
        var pressed: [String] = []
        func thing(_ id: String, _ x: Double, _ y: Double) -> FocusTarget { FocusTarget(id: id, at: (x, y), activate: { pressed.append(id) }) }
        focus.update([thing("search", 100, 20), thing("game:a", 50, 130), thing("game:b", 170, 130), thing("game:c", 50, 210)])
        XCTAssertTrue(focus.handle(.right), "The first press only reveals the focus")
        XCTAssertEqual(focus.selected, "game:a")
        XCTAssertTrue(focus.handle(.right)); XCTAssertEqual(focus.selected, "game:b")
        XCTAssertTrue(focus.handle(.right)); XCTAssertEqual(focus.selected, "game:b", "Nothing lies further")
        _ = focus.handle(.left); _ = focus.handle(.down)
        XCTAssertEqual(focus.selected, "game:c")
        XCTAssertTrue(focus.handle(.play))
        XCTAssertEqual(pressed, ["game:c"])
        XCTAssertFalse(focus.handle(.back), "Back is left to the page")
        XCTAssertFalse(focus.handle(.favorite))
        XCTAssertTrue(focus.isFocused("game:c")); XCTAssertFalse(focus.isFocused("game:a"))
        focus.update([thing("settings:close", 10, 10)])
        XCTAssertFalse(focus.handle(.back))
        XCTAssertEqual(focus.selected, "settings:close")
    }

    @MainActor func testAThingThatIsAdjustedTakesLeftAndRightForItself() async {
        let focus = FocusModel()
        var steps: [Int] = []
        focus.update([FocusTarget(id: "bitrate", at: (100, 100), activate: {}, adjust: { steps.append($0) }), FocusTarget(id: "next", at: (300, 100), activate: {})])
        focus.selected = "bitrate"
        XCTAssertTrue(focus.handle(.right)); XCTAssertTrue(focus.handle(.left))
        XCTAssertEqual(steps, [1, -1])
        XCTAssertEqual(focus.selected, "bitrate")
    }

    @MainActor func testAListOfChoicesTakesThePressesWhileItIsShown() async {
        let focus = FocusModel()
        var chosen: [String] = [], changes = 0
        focus.willChange = { changes += 1 }
        focus.selected = "language"
        focus.choices = ["English", "Russian", "Deutsch"].map { name in FocusModel.Choice(title: name) { chosen.append(name) } }
        XCTAssertFalse(focus.isFocused("language"), "The list covers what is under it")
        XCTAssertTrue(focus.handle(.up)); XCTAssertEqual(focus.choiceIndex, 0)
        _ = focus.handle(.down); _ = focus.handle(.right); _ = focus.handle(.down)
        XCTAssertEqual(focus.choiceIndex, 2, "It stops at its last row")
        XCTAssertTrue(focus.handle(.settings), "Unused presses are swallowed by the list")
        XCTAssertTrue(focus.handle(.play))
        XCTAssertEqual(chosen, ["Deutsch"]); XCTAssertTrue(focus.choices.isEmpty)
        focus.choices = [FocusModel.Choice(title: "One") { chosen.append("One") }]
        XCTAssertTrue(focus.handle(.back))
        XCTAssertTrue(focus.choices.isEmpty); XCTAssertEqual(chosen, ["Deutsch"])
        XCTAssertGreaterThan(changes, 6, "Every change is announced")
    }
}
