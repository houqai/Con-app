import Foundation
import SoleCore
import XCTest

extension XCTestCase {
    func testSettings(_ values: [String: Any] = [:]) -> UserDefaults {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("con-tests-\(UUID().uuidString).plist")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let defaults: UserDefaults = FileDefaults(file: file)
        for (key, value) in values { defaults.set(value, forKey: key) }
        return defaults
    }
}
