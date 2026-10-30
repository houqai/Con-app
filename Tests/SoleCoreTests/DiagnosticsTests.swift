import XCTest
@testable import SoleCore

final class DiagnosticsTests: XCTestCase {
    func testATestRunWritesItsDiagnosticsIntoAFolderOfItsOwn() {
        XCTAssertEqual(Diagnostics.directory, Diagnostics.testDirectory)
        XCTAssertNotEqual(Diagnostics.directory, Diagnostics.cachesDirectory)
    }
    func testTestRunnersAreDistinguishedFromTheApp() {
        XCTAssertTrue(Diagnostics.runsTests(processName: "xctest", bundles: []))
        XCTAssertTrue(Diagnostics.runsTests(processName: "swiftpm-testing-helper", bundles: []))
        XCTAssertTrue(Diagnostics.runsTests(processName: "ConPackageTests.exe", bundles: []))
        XCTAssertTrue(Diagnostics.runsTests(processName: "Con", bundles: ["/x/ConPackageTests.xctest"]))
        XCTAssertFalse(Diagnostics.runsTests(processName: "Con", bundles: ["/Applications/Con.app"]))
        XCTAssertFalse(Diagnostics.runsTests(processName: "con-app", bundles: []))
    }
}
