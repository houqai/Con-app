import Darwin
import Foundation

public final class HandOver: @unchecked Sendable {
    private struct Work { let time: UInt64; let run: () -> Void }
    private let lock = NSLock()
    private var queue: [Work] = []
    private var stopped = false
    private let signal = DispatchSemaphore(value: 0)

    public init() {
        let thread = Thread { [self] in
            Self.makeRealTime()
            run()
        }
        thread.name = "Con hand-over"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    public func submit(at time: UInt64, _ work: @escaping () -> Void) {
        lock.withLock { queue.append(Work(time: time, run: work)) }
        signal.signal()
    }

    public func stop() {
        lock.withLock { stopped = true; queue = [] }
        signal.signal()
    }

    private func run() {
        while true {
            signal.wait()
            let next = lock.withLock { () -> Work? in
                if stopped { return nil }
                return queue.isEmpty ? nil : queue.removeFirst()
            }
            guard let next else {
                if lock.withLock({ stopped }) { return }
                continue
            }
            let now = DispatchTime.now().uptimeNanoseconds
            if next.time > now, next.time - now < 100_000_000 { mach_wait_until(Self.machTime(next.time)) }
            next.run()
        }
    }

    private static let timebase: mach_timebase_info_data_t = { var info = mach_timebase_info_data_t(); mach_timebase_info(&info); return info }()

    static func machTime(_ nanoseconds: UInt64) -> UInt64 {
        nanoseconds * UInt64(timebase.denom) / UInt64(timebase.numer)
    }

    static func makeRealTime() {
        let interval = machTime(16_683_333)
        var policy = thread_time_constraint_policy_data_t(period: UInt32(interval), computation: UInt32(machTime(1_000_000)),
                                                         constraint: UInt32(machTime(4_000_000)), preemptible: 1)
        let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &policy) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_policy_set(pthread_mach_thread_np(pthread_self()), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
            }
        }
    }
}
