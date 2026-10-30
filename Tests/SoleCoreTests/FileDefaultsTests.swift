import Foundation
import XCTest
@testable import SoleCore

final class FileDefaultsTests: XCTestCase {
    private func file() -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("con-file-defaults-\(UUID().uuidString)").appendingPathComponent("settings.plist")
        addTeardownBlock { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        return file
    }

    func testWhatIsSetIsReadByItsKindAndKeptForTheNextStart() {
        let url = file()
        let defaults = FileDefaults(file: url)
        XCTAssertNil(defaults.string(forKey: "sole.language"))
        XCTAssertFalse(defaults.bool(forKey: "sole.touchGamepad"))
        defaults.set("ru", forKey: "sole.language")
        defaults.set(true, forKey: "sole.touchGamepad")
        defaults.set(42, forKey: "sole.bitrate")
        defaults.set(1.5, forKey: "sole.scale")
        defaults.set(Data([1, 2, 3]), forKey: "sole.blob")
        defaults.set(["a": "b"], forKey: "sole.map")
        defaults.set(["x", "y"], forKey: "sole.list")

        let again = FileDefaults(file: url)
        XCTAssertEqual(again.string(forKey: "sole.language"), "ru")
        XCTAssertTrue(again.bool(forKey: "sole.touchGamepad"))
        XCTAssertEqual(again.integer(forKey: "sole.bitrate"), 42)
        XCTAssertEqual(again.double(forKey: "sole.scale"), 1.5)
        XCTAssertEqual(again.data(forKey: "sole.blob"), Data([1, 2, 3]))
        XCTAssertEqual(again.dictionary(forKey: "sole.map") as? [String: String], ["a": "b"])
        XCTAssertEqual(again.stringArray(forKey: "sole.list"), ["x", "y"])
        XCTAssertEqual(again.object(forKey: "sole.touchGamepad") as? Bool, true)
    }

    func testARemovedValueGivesWayToTheRegisteredOne() {
        let defaults = FileDefaults(file: file())
        defaults.register(defaults: ["sole.volume": 80])
        XCTAssertEqual(defaults.integer(forKey: "sole.volume"), 80)
        defaults.set(30, forKey: "sole.volume")
        XCTAssertEqual(defaults.integer(forKey: "sole.volume"), 30)
        defaults.removeObject(forKey: "sole.volume")
        XCTAssertEqual(defaults.integer(forKey: "sole.volume"), 80)
        XCTAssertNil(defaults.string(forKey: "sole.nothing"))
        XCTAssertEqual(defaults.integer(forKey: "sole.nothing"), 0)
    }
}
