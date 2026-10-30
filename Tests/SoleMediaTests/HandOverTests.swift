import XCTest
@testable import SoleMedia

final class HandOverTests: XCTestCase {
    func testWorkIsDoneAtItsTimeInTurn() {
        let handOver = HandOver()
        defer { handOver.stop() }
        final class Done: @unchecked Sendable { var at: [(Int, UInt64)] = []; let lock = NSLock() }
        let done = Done(), finished = expectation(description: "done")
        let start = DispatchTime.now().uptimeNanoseconds + 20_000_000
        let times = (0..<20).map { start + UInt64($0) * 16_683_333 }
        for (index, time) in times.enumerated() {
            handOver.submit(at: time) {
                done.lock.withLock { done.at.append((index, DispatchTime.now().uptimeNanoseconds)) }
                if index == times.count - 1 { finished.fulfill() }
            }
        }
        wait(for: [finished], timeout: 2)
        let at = done.lock.withLock { done.at }
        XCTAssertEqual(at.map(\.0), Array(0..<20), "In order")
        for (index, when) in at {
            XCTAssertGreaterThanOrEqual(when, times[index], "Not before its time")
            XCTAssertLessThan(when - times[index], 3_000_000, "Late by less than 3 ms")
        }
    }

    func testWorkFarAheadOrPastIsDoneAtOnce() {
        let handOver = HandOver()
        defer { handOver.stop() }
        let done = expectation(description: "done")
        let asked = DispatchTime.now().uptimeNanoseconds
        handOver.submit(at: 0) { XCTAssertLessThan(DispatchTime.now().uptimeNanoseconds - asked, 50_000_000); done.fulfill() }
        wait(for: [done], timeout: 1)
    }
}
