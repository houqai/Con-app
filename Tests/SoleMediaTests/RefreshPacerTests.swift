import XCTest
@testable import SoleMedia

final class RefreshPacerTests: XCTestCase {
    func testWithoutARefreshToGoByAPictureGoesAtOnce() {
        let pacer = RefreshPacer()
        XCTAssertFalse(pacer.isRunning)
        var done = 0
        pacer.submit { done += 1 }
        pacer.submit { done += 1 }
        XCTAssertEqual(done, 2)
        XCTAssertEqual(pacer.dropped, 0)
    }

    @MainActor func testInAWindowOnePictureGoesAtEachRefreshInTurn() async throws {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let pacer = RefreshPacer()
        pacer.attach(to: view)
        defer { pacer.attach(to: nil) }
        try XCTSkipUnless(pacer.isRunning, "No display refresh available")
        final class Order: @unchecked Sendable { var done: [Int] = []; let lock = NSLock() }
        let order = Order()
        for index in 0..<5 { pacer.submit { order.lock.withLock { order.done.append(index) } } }
        for _ in 0..<50 where order.lock.withLock({ order.done.last }) != 4 { try await Task.sleep(nanoseconds: 10_000_000) }
        let done = order.lock.withLock { order.done }
        XCTAssertEqual(done.last, 4)
        XCTAssertEqual(done, done.sorted())
        XCTAssertEqual(done.count + pacer.dropped, 5)
        XCTAssertGreaterThanOrEqual(pacer.dropped, 2)
    }
}
