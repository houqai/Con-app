import Foundation

public final class VideoCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var stats = VideoStats()
    public init() {}
    @discardableResult public func update<Result>(_ change: (inout VideoStats) -> Result) -> Result {
        lock.lock(); defer { lock.unlock() }
        return change(&stats)
    }
    public var snapshot: VideoStats { update { $0 } }
}

public struct GeneratedPicture<Buffer>: @unchecked Sendable {
    public let buffer: Buffer
    public init(_ buffer: Buffer) { self.buffer = buffer }
}

public protocol PictureGenerator<Buffer>: Sendable {
    associatedtype Buffer
    func configure(width: Int, height: Int, limit: Int) async throws
    func interpolate(previous: sending Buffer, current: sending Buffer, previousTime: UInt64, currentTime: UInt64) async throws -> GeneratedPicture<Buffer>?
    func end() async throws
}

public final class PictureQueue<Buffer>: @unchecked Sendable {
    private struct Picture: @unchecked Sendable {
        let buffer: Buffer
        let time: UInt64
        var generated = false
        var isNew = true
        var discontinuity = false
        var decodedAt: UInt64
    }

    private let lock = NSLock()
    private let counters: VideoCounters
    private let clock: @Sendable () -> UInt64
    private let size: @Sendable (Buffer) -> (width: Int, height: Int)
    private let display: @Sendable (Buffer, UInt64) -> Void
    private let makeGenerator: @Sendable () -> (any PictureGenerator<Buffer>)?
    private var generationWanted = false
    private var refresh = 60.0
    private var generationLimit = GenerationState.defaultHeight
    private let pictures: AsyncStream<Picture>.Continuation
    private let showing: AsyncStream<Picture>.Continuation
    private var presenter: Task<Void, Never>?
    private var shower: Task<Void, Never>?
    private var allowance: UInt64 = 14_000_000
    private var lastScheduled: UInt64 = 0
    private var generator: (any PictureGenerator<Buffer>)?
    private var generatorSize: (Int, Int, Int)?
    private var generatorRequest = 0
    private var generatorLoading = false
    private var room = GenerationRoom()
    private var generatorFailures = 0
    private var heldBack: UInt64 = 0

    public init(counters: VideoCounters,
                generator: @escaping @Sendable () -> (any PictureGenerator<Buffer>)?,
                size: @escaping @Sendable (Buffer) -> (width: Int, height: Int),
                show: @escaping @Sendable (Buffer, UInt64) -> Void,
                clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.counters = counters
        makeGenerator = generator
        self.size = size
        display = show
        self.clock = clock
        let (stream, continuation) = AsyncStream.makeStream(of: Picture.self, bufferingPolicy: .bufferingNewest(4))
        pictures = continuation
        let (shown, shownContinuation) = AsyncStream.makeStream(of: Picture.self, bufferingPolicy: .bufferingNewest(8))
        showing = shownContinuation
        presenter = Task.detached(priority: .userInitiated) { [weak self] in
            var previous: Picture?
            for await picture in stream {
                guard let self else { return }
                let now = self.clock()
                self.counters.update { $0.prepareQueueMs = Double(now - picture.decodedAt) / 1_000_000 }
                await self.prepare(picture, after: picture.discontinuity ? nil : previous)
                if picture.isNew || previous == nil { previous = picture }
            }
        }
        shower = Task.detached(priority: .userInitiated) { [weak self] in
            for await picture in shown {
                guard let self, !Task.isCancelled else { return }
                if self.clock() > picture.time + PresentationClock.interval {
                    self.counters.update { $0.lateFrames += 1 }
                    continue
                }
                self.display(picture.buffer, picture.time)
                let delay = Double(self.clock() - picture.decodedAt) / 1_000_000
                self.counters.update {
                    if picture.generated {
                        $0.generatedFrames += 1
                    } else {
                        $0.deliveryMs = delay
                        $0.maxDeliveryMs = max($0.maxDeliveryMs, delay)
                        $0.shownFrames += 1
                    }
                }
            }
        }
    }

    public var frameGeneration: Bool {
        get { lock.withLock { generationWanted } }
        set {
            lock.withLock { generationWanted = newValue }
            if !newValue { counters.update { $0.generation = .off; $0.addedDelayMs = 0 } }
        }
    }
    public var displayRate: Double {
        get { lock.withLock { refresh } }
        set { lock.withLock { if newValue > 0 { refresh = newValue } } }
    }
    public var generationHeight: Int {
        get { lock.withLock { generationLimit } }
        set { lock.withLock { if newValue > 0 { generationLimit = newValue } } }
    }

    public func submit(_ buffer: Buffer, time: UInt64, isNew: Bool, discontinuity: Bool, decodedAt: UInt64) {
        if case .dropped = pictures.yield(Picture(buffer: buffer, time: time, isNew: isNew, discontinuity: discontinuity, decodedAt: decodedAt)) {
            counters.update { $0.queueDrops += 1 }
        }
    }

    public func invalidate() {
        pictures.finish(); showing.finish()
        presenter?.cancel(); presenter = nil
        shower?.cancel(); shower = nil
    }
    deinit { invalidate() }

    private func prepare(_ picture: Picture, after previous: Picture?) async {
        guard picture.isNew || previous == nil else {
            if heldBack > 0, let previous, picture.time < previous.time + 100_000_000 {
                counters.update { $0.suppressedRepeats += 1 }
                return
            }
            schedule(Picture(buffer: picture.buffer, time: picture.time + heldBack, decodedAt: picture.decodedAt))
            return
        }
        var time = picture.time
        if frameGeneration {
            time = await generate(before: picture, after: previous)
        } else {
            let unused: (any PictureGenerator<Buffer>)? = lock.withLock {
                guard generator != nil || generatorSize != nil else { return nil }
                defer { generator = nil; generatorSize = nil; generatorLoading = false; generatorRequest += 1 }
                return generator
            }
            generatorFailures = 0
            try? await unused?.end()
        }
        heldBack = time - picture.time
        schedule(Picture(buffer: picture.buffer, time: time, decodedAt: picture.decodedAt))
    }

    private func schedule(_ picture: Picture) {
        lastScheduled = max(lastScheduled, picture.time)
        if case .dropped = showing.yield(Picture(buffer: picture.buffer, time: lastScheduled, generated: picture.generated, decodedAt: picture.decodedAt)) {
            counters.update { $0.queueDrops += 1 }
        }
    }

    private func generate(before picture: Picture, after previous: Picture?) async -> UInt64 {
        guard let previous, picture.time > previous.time, picture.time - previous.time < 100_000_000 else { return picture.time }
        let interval = picture.time - previous.time
        guard room.take(interval: interval, refresh: displayRate) else {
            let wanted = frameGeneration
            counters.update { if wanted { $0.generation = .standby; $0.addedDelayMs = 0 } }
            return picture.time
        }
        let dimensions = size(picture.buffer)
        let wantedSize = (dimensions.width, dimensions.height, generationHeight)
        let request: Int? = lock.withLock {
            guard generatorSize.map({ $0 != wantedSize }) ?? true else { return nil }
            generator = nil; generatorSize = wantedSize; generatorLoading = true; generatorRequest += 1
            return generatorRequest
        }
        if let request {
            generatorFailures = 0
            let make = makeGenerator
            Task.detached { [weak self] in
                let prepared = make()
                let ready = (try? await prepared?.configure(width: wantedSize.0, height: wantedSize.1, limit: wantedSize.2)) != nil
                self?.lock.withLock {
                    guard let self, self.generatorRequest == request else { return }
                    self.generator = ready ? prepared : nil
                    self.generatorLoading = false
                }
            }
        }
        let state: (generator: (any PictureGenerator<Buffer>)?, loading: Bool, wanted: Bool) = lock.withLock { (generator, generatorLoading, generationWanted) }
        counters.update {
            if state.wanted { $0.generation = state.generator != nil ? .active : state.loading ? .preparing : .unavailable }
            if state.generator == nil { $0.addedDelayMs = 0 }
        }
        guard let generator = state.generator else { return picture.time }
        let middleTime = picture.time + allowance
        let pictureTime = middleTime + interval / 2
        let added = Double(allowance + interval / 2) / 1_000_000
        counters.update { $0.addedDelayMs = added }
        let started = clock()
        guard started < middleTime else { return pictureTime }
        let middle: GeneratedPicture<Buffer>?
        do {
            middle = try await generator.interpolate(previous: previous.buffer, current: picture.buffer, previousTime: previous.time, currentTime: picture.time)
            generatorFailures = 0
        } catch {
            generatorFailures += 1
            guard generatorFailures >= Self.failuresToGiveUp else { return pictureTime }
            let wanted: Bool = lock.withLock { self.generator = nil; return generationWanted }
            counters.update {
                if wanted { $0.generation = .unavailable }
                $0.addedDelayMs = 0
            }
            try? await generator.end()
            return picture.time
        }
        guard let middle else { return pictureTime }
        let spent = clock() - started
        schedule(Picture(buffer: middle.buffer, time: middleTime, generated: true, decodedAt: clock()))
        let wanted = spent + spent / 4 + 1_000_000
        allowance = min(max((allowance * 7 + wanted) / 8, 4_000_000), max(interval, 4_000_000))
        counters.update { $0.generationMs = Double(spent) / 1_000_000 }
        return pictureTime
    }
    var hasGenerator: Bool { lock.withLock { generator != nil } }
    public static var failuresToGiveUp: Int { 3 }
}
