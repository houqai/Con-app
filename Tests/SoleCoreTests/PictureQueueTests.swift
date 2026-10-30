import XCTest
@testable import SoleCore

final class PictureQueueTests: XCTestCase {
    private final class Screen: @unchecked Sendable {
        private let lock = NSLock()
        private var pictures: [(buffer: Int, time: UInt64)] = []
        private var time: UInt64
        init(now: UInt64) { time = now }
        func show(_ buffer: Int, at time: UInt64) { lock.withLock { pictures.append((buffer, time)) } }
        var shown: [(buffer: Int, time: UInt64)] { lock.withLock { pictures } }
        var now: UInt64 {
            get { lock.withLock { time } }
            set { lock.withLock { time = newValue } }
        }
    }
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func add() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }
    private final class Generator: PictureGenerator, @unchecked Sendable {
        private let lock = NSLock()
        private var state = (configured: [[Int]](), asked: 0, ended: 0, failing: false, loaded: false)
        func configure(width: Int, height: Int, limit: Int) async throws {
            var tries = 0
            while !lock.withLock({ state.loaded }), tries < 10_000 {
                try? await Task.sleep(nanoseconds: 1_000_000)
                tries += 1
            }
            lock.withLock { state.configured.append([width, height, limit]) }
        }
        func finishLoading() { lock.withLock { state.loaded = true } }
        func interpolate(previous: sending Int, current: sending Int, previousTime: UInt64, currentTime: UInt64) async throws -> GeneratedPicture<Int>? {
            let fail = lock.withLock { state.asked += 1; return state.failing }
            if fail { throw CancellationError() }
            return GeneratedPicture(-current)
        }
        func end() async throws { lock.withLock { state.ended += 1 } }
        var configured: [[Int]] { lock.withLock { state.configured } }
        var asked: Int { lock.withLock { state.asked } }
        var ended: Int { lock.withLock { state.ended } }
        var failing: Bool {
            get { lock.withLock { state.failing } }
            set { lock.withLock { state.failing = newValue } }
        }
    }

    private let base: UInt64 = 10_000_000_000
    private let thirty: UInt64 = 33_333_333
    private let sixty: UInt64 = 16_666_667
    private let allowance: UInt64 = 14_000_000

    private func wait(_ what: String, _ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<600 { if condition() { return }; try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTFail("Waited three seconds for: \(what)", file: file, line: line)
    }
    private func load(_ generator: Generator, into queue: PictureQueue<Int>, file: StaticString = #filePath, line: UInt = #line) async {
        generator.finishLoading()
        await wait("the generator", { queue.hasGenerator }, file: file, line: line)
    }
    private func make(generator: Generator? = nil, made: (@Sendable () -> Void)? = nil) -> (queue: PictureQueue<Int>, screen: Screen, counters: VideoCounters) {
        let screen = Screen(now: base), counters = VideoCounters()
        let queue = PictureQueue<Int>(counters: counters, generator: { made?(); return generator }, size: { _ in (1920, 1080) },
                                      show: { screen.show($0, at: $1) }, clock: { screen.now })
        return (queue, screen, counters)
    }
    private func feed(_ queue: PictureQueue<Int>, _ counters: VideoCounters, _ picture: Int, at time: UInt64, isNew: Bool = true, discontinuity: Bool = false,
                      file: StaticString = #filePath, line: UInt = #line) async {
        func through() -> Int { let stats = counters.snapshot; return stats.shownFrames + stats.suppressedRepeats + stats.lateFrames }
        let before = through()
        queue.submit(picture, time: time, isNew: isNew, discontinuity: discontinuity, decodedAt: base)
        await wait("picture \(picture)", { through() == before + 1 }, file: file, line: line)
    }

    func testWithoutGenerationEveryPictureIsShownAtItsTimeAndNeverBeforeTheOneBefore() async {
        let (queue, screen, counters) = make()
        await feed(queue, counters, 1, at: base)
        await feed(queue, counters, 2, at: base + sixty)
        await feed(queue, counters, 2, at: base + 2 * sixty, isNew: false)
        await feed(queue, counters, 3, at: base + sixty)
        XCTAssertEqual(screen.shown.map(\.buffer), [1, 2, 2, 3], "A repeat is a picture like any other")
        XCTAssertEqual(screen.shown.map(\.time), [base, base + sixty, base + 2 * sixty, base + 2 * sixty], "A picture timed before the last one is shown with it, not before it")
        let stats = counters.snapshot
        XCTAssertEqual(stats.shownFrames, 4); XCTAssertEqual(stats.generatedFrames, 0); XCTAssertEqual(stats.generation, .off); XCTAssertEqual(stats.addedDelayMs, 0)
        queue.invalidate()
    }

    func testAGeneratedPictureGoesBetweenTwoAndHoldsThePictureBackByTheAllowanceAndHalfAnInterval() async {
        let generator = Generator()
        let (queue, screen, counters) = make(generator: generator)
        queue.frameGeneration = true; queue.displayRate = 60; queue.generationHeight = 1080
        await feed(queue, counters, 1, at: base)
        await feed(queue, counters, 2, at: base + thirty)
        XCTAssertEqual(counters.snapshot.generation, .preparing, "The generator is being made ready; pictures go on meanwhile")
        XCTAssertEqual(screen.shown.map(\.time), [base, base + thirty])
        await load(generator, into: queue)
        XCTAssertEqual(generator.configured, [[1920, 1080, 1080]])
        await feed(queue, counters, 3, at: base + 2 * thirty)
        await wait("the generated picture", { counters.snapshot.generatedFrames == 1 })
        XCTAssertEqual(Array(screen.shown.suffix(2)).map(\.buffer), [-3, 3])
        XCTAssertEqual(Array(screen.shown.suffix(2)).map(\.time), [base + 2 * thirty + allowance, base + 2 * thirty + allowance + thirty / 2])
        var stats = counters.snapshot
        XCTAssertEqual(stats.generation, .active)
        XCTAssertEqual(stats.addedDelayMs, Double(allowance + thirty / 2) / 1_000_000, accuracy: 0.001)
        await feed(queue, counters, 3, at: base + 2 * thirty + sixty, isNew: false)
        XCTAssertEqual(counters.snapshot.suppressedRepeats, 1)
        await feed(queue, counters, 4, at: base + 3 * thirty)
        await wait("the second generated picture", { counters.snapshot.generatedFrames == 2 })
        let next: UInt64 = (allowance * 7 + 1_000_000) / 8
        XCTAssertEqual(Array(screen.shown.suffix(2)).map(\.time), [base + 3 * thirty + next, base + 3 * thirty + next + thirty / 2])
        await feed(queue, counters, 4, at: base + 3 * thirty + 150_000_000, isNew: false)
        stats = counters.snapshot
        XCTAssertEqual(stats.suppressedRepeats, 1)
        XCTAssertEqual(screen.shown.last?.time, base + 3 * thirty + 150_000_000 + next + thirty / 2)
        XCTAssertEqual(generator.asked, 2)
        queue.invalidate()
    }

    func testNothingIsGeneratedOrHeldBackWhenTheDisplayIsAsFastAsTheGame() async {
        let generator = Generator()
        let made = Counter()
        let (queue, screen, counters) = make(generator: generator, made: { made.add() })
        queue.frameGeneration = true; queue.displayRate = 60
        for step in 0..<5 { await feed(queue, counters, step, at: base + UInt64(step) * sixty) }
        XCTAssertEqual(screen.shown.map(\.time), (0..<5).map { base + UInt64($0) * sixty })
        let stats = counters.snapshot
        XCTAssertEqual(stats.generation, .standby); XCTAssertEqual(stats.generatedFrames, 0); XCTAssertEqual(stats.addedDelayMs, 0)
        XCTAssertEqual(made.count, 0, "The generator is not even made while there is no room for its pictures")
        queue.invalidate()
    }

    func testAGeneratorThatKeepsFailingIsGivenUpAndThePicturesAreNotHeldBackForIt() async {
        let generator = Generator()
        generator.failing = true
        let (queue, screen, counters) = make(generator: generator)
        queue.frameGeneration = true; queue.displayRate = 60
        await feed(queue, counters, 1, at: base)
        await feed(queue, counters, 2, at: base + thirty)
        await load(generator, into: queue)
        let held = allowance + thirty / 2
        await feed(queue, counters, 3, at: base + 2 * thirty)
        await feed(queue, counters, 4, at: base + 3 * thirty)
        XCTAssertEqual(Array(screen.shown.suffix(2)).map(\.time), [base + 2 * thirty + held, base + 3 * thirty + held], "One failure may be a hiccup: the pictures keep their place")
        XCTAssertEqual(counters.snapshot.generation, .active)
        await feed(queue, counters, 5, at: base + 4 * thirty + held)
        XCTAssertEqual(PictureQueue<Int>.failuresToGiveUp, 3)
        var stats = counters.snapshot
        XCTAssertEqual(stats.generation, .unavailable); XCTAssertEqual(stats.addedDelayMs, 0); XCTAssertEqual(stats.generatedFrames, 0)
        XCTAssertEqual(screen.shown.last?.time, base + 4 * thirty + held, "Shown at its own time again")
        XCTAssertEqual(generator.ended, 1)
        await feed(queue, counters, 6, at: base + 5 * thirty + held)
        XCTAssertEqual(generator.asked, 3, "It is not asked again for pictures of this size")
        stats = counters.snapshot
        XCTAssertEqual(stats.generation, .unavailable)
        queue.invalidate()
    }

    func testTurnedOffTheGeneratorIsLetGoAndTheDelayIsGone() async {
        let generator = Generator()
        let (queue, screen, counters) = make(generator: generator)
        queue.frameGeneration = true; queue.displayRate = 60
        await feed(queue, counters, 1, at: base)
        await feed(queue, counters, 2, at: base + thirty)
        await load(generator, into: queue)
        await feed(queue, counters, 3, at: base + 2 * thirty)
        await wait("the generated picture", { counters.snapshot.generatedFrames == 1 })
        queue.frameGeneration = false
        XCTAssertEqual(counters.snapshot.generation, .off); XCTAssertEqual(counters.snapshot.addedDelayMs, 0)
        let late = base + 2 * thirty + allowance + thirty / 2
        await feed(queue, counters, 4, at: late + thirty)
        XCTAssertEqual(screen.shown.last?.time, late + thirty, "At its own time")
        await wait("the generator to be ended", { generator.ended == 1 })
        await feed(queue, counters, 4, at: late + thirty + sixty, isNew: false)
        XCTAssertEqual(counters.snapshot.suppressedRepeats, 0, "Nothing is generated: a repeat is shown")
        queue.invalidate()
    }

    func testNothingIsGeneratedAcrossLostPicturesOrAPause() async {
        let generator = Generator()
        let (queue, screen, counters) = make(generator: generator)
        queue.frameGeneration = true; queue.displayRate = 60
        await feed(queue, counters, 1, at: base)
        await feed(queue, counters, 2, at: base + thirty)
        await load(generator, into: queue)
        await feed(queue, counters, 3, at: base + 2 * thirty, discontinuity: true)
        await feed(queue, counters, 4, at: base + 2 * thirty + 200_000_000)
        XCTAssertEqual(generator.asked, 0)
        XCTAssertEqual(Array(screen.shown.suffix(2)).map(\.time), [base + 2 * thirty, base + 2 * thirty + 200_000_000])
        XCTAssertEqual(counters.snapshot.generatedFrames, 0)
        queue.invalidate()
    }

    func testAPictureWhoseTimeHasPassedIsNotShown() async {
        let (queue, screen, counters) = make()
        await feed(queue, counters, 1, at: base)
        screen.now = base + 1_000_000_000
        await feed(queue, counters, 2, at: base + sixty)
        XCTAssertEqual(screen.shown.map(\.buffer), [1])
        XCTAssertEqual(counters.snapshot.lateFrames, 1)
        await feed(queue, counters, 3, at: base + 1_000_000_000 + sixty)
        XCTAssertEqual(screen.shown.map(\.buffer), [1, 3], "The stream goes on from where it is")
        queue.invalidate()
    }

    func testMoreWaitingPicturesThanTheQueueHoldsAreCountedAsDropped() async {
        let (queue, _, counters) = make()
        for step in 0..<400 { queue.submit(step, time: base + UInt64(step), isNew: true, discontinuity: false, decodedAt: base) }
        await wait("the queue to settle", {
            let stats = counters.snapshot
            return stats.shownFrames + stats.queueDrops == 400
        })
        XCTAssertGreaterThan(counters.snapshot.queueDrops, 0, "Four hundred at once do not fit a queue of four")
        queue.invalidate()
    }
}
