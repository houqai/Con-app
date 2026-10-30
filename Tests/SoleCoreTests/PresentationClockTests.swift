import XCTest
@testable import SoleCore

final class PresentationClockTests: XCTestCase {
    private let interval = Int(PresentationClock.interval)
    private let lead = Int(PresentationClock.lead)
    private let limit = Int(PresentationClock.limit)
    private let start = 1_000_000_000
    private let ntscInterval = 16_683_333

    private func feed(_ clock: inout PresentationClock, frames: Range<Int>, isNew: (Int) -> Bool = { _ in true },
                      arrival: (Int) -> Int) -> [(arrival: Int, time: Int)] {
        frames.map { index in
            let arrived = arrival(index)
            return (arrived, Int(clock.timestamp(arrival: UInt64(arrived), frame: index & 0xffff, isNew: isNew(index))))
        }
    }
    private func jitter(_ index: Int) -> Int { (index * 7919 % 6001 - 3000) * 1000 }

    func testEvenArrivalsAreTimedEvenlyAheadOfTheClock() {
        var clock = PresentationClock()
        let timed = feed(&clock, frames: 0..<300) { self.start + $0 * self.interval }
        XCTAssertTrue(timed.allSatisfy { $0.time - $0.arrival == lead })
    }

    func testJitterInArrivalsDoesNotReachTheScreen() {
        var clock = PresentationClock()
        let timed = Array(feed(&clock, frames: 0..<1500) { self.start + $0 * self.interval + self.jitter($0) }.dropFirst(300))
        let arrivalSteps = zip(timed.dropFirst(), timed).map { abs($0.arrival - $1.arrival - interval) }
        let steps = zip(timed.dropFirst(), timed).map { abs($0.time - $1.time - interval) }
        XCTAssertGreaterThan(arrivalSteps.max()!, 4_000_000)
        XCTAssertLessThanOrEqual(steps.max()!, 400_000)
        XCTAssertLessThan(steps.reduce(0, +) / steps.count, 20_000)
        let ahead = timed.map { $0.time - $0.arrival }.sorted()
        XCTAssertGreaterThan(Double(ahead.filter { $0 >= lead }.count) / Double(ahead.count), 0.95)
        XCTAssertLessThan(ahead[ahead.count / 2], lead + 4_500_000)
        XCTAssertTrue(timed.allSatisfy { $0.time >= $0.arrival })
    }

    func testAStallIsShownAtOnceAndLeavesTheGridInPlace() {
        var clock = PresentationClock()
        let timed = feed(&clock, frames: 0..<700) { index in
            (600...606).contains(index) ? self.start + 606 * self.interval + (index - 600) * 1_000_000 : self.start + index * self.interval
        }
        for index in 600...604 { XCTAssertEqual(timed[index].time, timed[index].arrival, "frame \(index)") }
        for index in 605...606 { XCTAssertLessThan(timed[index].time - timed[index].arrival, lead, "frame \(index)") }
        XCTAssertEqual(timed[599].time - timed[599].arrival, lead)
        for index in 607..<700 {
            XCTAssertGreaterThanOrEqual(timed[index].time - timed[index].arrival, lead)
            XCTAssertLessThan(timed[index].time - timed[index].arrival, lead + 3_000_000)
        }
    }

    func testTheGridFollowsAStreamThatStartedRunningLater() {
        var clock = PresentationClock()
        let timed = feed(&clock, frames: 0..<400) { self.start + $0 * self.interval + ($0 >= 300 ? 50_000_000 : 0) }
        XCTAssertEqual(timed[300].time, timed[300].arrival)
        for index in 301..<400 { XCTAssertEqual(timed[index].time - timed[index].arrival, lead, "frame \(index)") }
    }

    func testNoPictureWaitsLongAfterTheStreamCatchesUp() {
        var clock = PresentationClock()
        let late = 50_000_000
        let timed = feed(&clock, frames: 0..<900) { index in
            if index < 300 { return self.start + index * self.interval }
            if index < 600 { return self.start + index * self.interval + late }
            return max(self.start + index * self.interval, self.start + 599 * self.interval + late + (index - 599) * 8_000_000)
        }
        XCTAssertLessThanOrEqual(timed.map { $0.time - $0.arrival }.max()!, lead + limit)
        XCTAssertLessThan(timed[899].time - timed[899].arrival, lead + 9_000_000)
        XCTAssertTrue(zip(timed.dropFirst(), timed).allSatisfy { $0.time >= $1.time })
    }

    func testMissingFramesKeepTheirSlots() {
        var clock = PresentationClock()
        let first = clock.timestamp(arrival: UInt64(start), frame: 100)
        let next = clock.timestamp(arrival: UInt64(start + 3 * interval), frame: 103)
        XCTAssertEqual(Int(next - first), 3 * interval)
    }

    func testCounterWrapKeepsTheGrid() {
        var clock = PresentationClock()
        let first = clock.timestamp(arrival: UInt64(start), frame: 65535)
        let next = clock.timestamp(arrival: UInt64(start + interval), frame: 0)
        XCTAssertEqual(Int(next - first), interval)
    }

    func testALongGapStartsTheGridOver() {
        var clock = PresentationClock()
        _ = clock.timestamp(arrival: UInt64(start), frame: 100)
        XCTAssertEqual(Int(clock.timestamp(arrival: UInt64(2 * start), frame: 160)), 2 * start + lead)
    }

    func testMeasuresTheFrameIntervalOfTheStream() {
        var clock = PresentationClock()
        _ = feed(&clock, frames: 0..<1000) { self.start + $0 * self.ntscInterval + self.jitter($0) }
        XCTAssertEqual(clock.frameInterval, Double(interval), "a few seconds are not enough to tell 59.94 from 60")
        _ = feed(&clock, frames: 1000..<3000) { self.start + $0 * self.ntscInterval + self.jitter($0) }
        XCTAssertEqual(clock.frameInterval, Double(ntscInterval), accuracy: 1_000)
        _ = feed(&clock, frames: 3000..<6000) { self.start + $0 * self.ntscInterval + self.jitter($0) + 48_000_000 }
        XCTAssertEqual(clock.frameInterval, Double(ntscInterval), accuracy: 1_000)
    }

    func testRepeatsDoNotPullTheGridButKeepItNearTheArrivals() {
        var clock = PresentationClock()
        let arrival: (Int) -> Int = { self.start + $0 * self.interval + ($0 % 2 == 0 ? 0 : -7_000_000) }
        let timed = feed(&clock, frames: 0..<1200, isNew: { $0 % 2 == 0 }, arrival: arrival)
        for index in stride(from: 600, to: 1200, by: 2) { XCTAssertEqual(timed[index].time - timed[index].arrival, lead, "frame \(index)") }

        var still = PresentationClock()
        _ = feed(&still, frames: 0..<3600, isNew: { $0 == 0 }) { self.start + $0 * self.ntscInterval }
        let after = Int(still.timestamp(arrival: UInt64(start + 3600 * ntscInterval), frame: 3600))
        XCTAssertEqual(after - (start + 3600 * ntscInterval), lead, accuracy: 100_000)
    }

    func testASmallerLeadTimesPicturesThatMuchAhead() {
        var clock = PresentationClock(lead: 8_000_000)
        let timed = feed(&clock, frames: 0..<300) { self.start + $0 * self.interval }
        XCTAssertTrue(timed.allSatisfy { $0.time - $0.arrival == 8_000_000 })
        XCTAssertEqual(PresentationClock(lead: -1).lead, 0)
    }
}
