import AppKit
import Foundation
import QuartzCore

public final class RefreshPacer: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [() -> Void] = []
    private var link: CADisplayLink?
    private lazy var ticker = Ticker(self)
    private static let loop = RefreshLoop()
    static let kept = 2
    private var droppedCount = 0

    public init() {}

    public var dropped: Int { lock.withLock { droppedCount } }

    public var isRunning: Bool { lock.withLock { link != nil } }

    @MainActor public func attach(to view: NSView?) {
        let old = lock.withLock { () -> CADisplayLink? in defer { link = nil }; return link }
        old?.invalidate()
        guard let view, view.window != nil else { flush(); return }
        let link = view.displayLink(target: ticker, selector: #selector(Ticker.tick(_:)))
        Self.loop.add(link)
        lock.withLock { self.link = link }
    }

    public func submit(_ work: @escaping () -> Void) {
        let now = lock.withLock { () -> Bool in
            guard link != nil else { return true }
            waiting.append(work)
            while waiting.count > Self.kept { waiting.removeFirst(); droppedCount += 1 }
            return false
        }
        if now { work() }
    }

    public func clear() { lock.withLock { waiting = [] } }

    public func flush() {
        let last = lock.withLock { () -> (() -> Void)? in defer { waiting = [] }; return waiting.last }
        last?()
    }

    fileprivate func refresh() {
        let next = lock.withLock { () -> (() -> Void)? in waiting.isEmpty ? nil : waiting.removeFirst() }
        next?()
    }

    private final class Ticker: NSObject {
        weak var pacer: RefreshPacer?
        init(_ pacer: RefreshPacer) { self.pacer = pacer }
        @objc func tick(_ link: CADisplayLink) { pacer?.refresh() }
    }

    private final class RefreshLoop: @unchecked Sendable {
        private var loop: RunLoop?
        private let ready = DispatchSemaphore(value: 0)
        init() {
            let thread = Thread { [unowned self] in
                HandOver.makeRealTime()
                self.loop = RunLoop.current
                RunLoop.current.add(NSMachPort(), forMode: .common)
                self.ready.signal()
                while true { RunLoop.current.run(mode: .default, before: .distantFuture) }
            }
            thread.name = "Con refreshes"
            thread.qualityOfService = .userInteractive
            thread.start()
            ready.wait()
        }
        func add(_ link: CADisplayLink) { link.add(to: loop!, forMode: .default) }
    }
}
