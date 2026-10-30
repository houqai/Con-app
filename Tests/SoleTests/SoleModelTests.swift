import XCTest
import Combine
@testable import Sole
import SoleCloud
import SoleCore
import SoleLogic

final class SoleModelTests: XCTestCase {
    private func settings() -> UserDefaults {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("con-tests-\(UUID().uuidString).plist")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        return FileDefaults(file: file)
    }

    @MainActor func testSearchAndReplacementStayCurrentWhileSelectionChanges() {
        let model = SoleModel(defaults: settings())
        model.filter = .all
        let first = Game(id: "test-a", title: "Alpha", platform: "PS5", favorite: false, artworkURL: nil)
        let second = Game(id: "test-b", title: "Beta", platform: "PS5", favorite: false, artworkURL: nil)
        model.catalogGames = [first, second]
        XCTAssertEqual(model.orderedGames.map(\.id), [first.id, second.id])
        model.search = "Beta"
        XCTAssertEqual(model.filteredGames.map(\.id), [second.id])
        model.showGame(first)
        XCTAssertEqual(model.filteredGames.map(\.id), [second.id])
        model.catalogGames = [first]
        XCTAssertTrue(model.filteredGames.isEmpty)
        model.search = ""
        XCTAssertEqual(model.orderedGames.map(\.id), [first.id])
    }

    @MainActor func testSwiftUIIsToldBeforeAnythingItShowsChanges() {
        let model = SoleModel(defaults: settings())
        var notifications = 0
        var seen: [String] = []
        let watching = model.objectWillChange.sink { notifications += 1; seen.append(model.search) }
        model.search = "a"
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(seen, [""], "Before the change, as SwiftUI expects")
        model.settingsOpen = true; model.bitrate = 12; model.toggleFavorite("x")
        XCTAssertGreaterThanOrEqual(notifications, 4)
        let before = notifications
        model.catalogGames.append(Game(id: "g", title: "G", platform: "PS5", favorite: false, artworkURL: nil))
        XCTAssertEqual(notifications, before + 1, "Mutating the list in place counts as a change")
        watching.cancel()
    }

    @MainActor func testTheModelPlaysOnThisMacAndKeepsItsSettingsWhereItIsTold() {
        let store = settings()
        store.set("fill", forKey: "sole.videoFit")
        let model = SoleModel(defaults: store)
        XCTAssertEqual(model.videoFit, "fill")
        model.destination = .consoles
        XCTAssertEqual(model.destination, Destination.consolesShown ? .consoles : .cloud)
        model.destination = .cloud
        XCTAssertEqual(model.destination, .cloud)
        model.selectPreset(540)
        XCTAssertEqual(store.integer(forKey: "sole.resolution"), 540)
        XCTAssertEqual(SettingsSection.allCases.count, 5)
    }
}
