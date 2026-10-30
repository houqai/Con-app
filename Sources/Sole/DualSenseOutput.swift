import Foundation
import GameController
import IOKit.hid
import SoleEngine
import SoleMedia

final class DualSenseOutput: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.sole.dualsense-output", qos: .userInteractive)
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var driver = DualSenseDriver()
    private var nextDeviceAttempt = Date.distantPast
    private static let noOptions = IOOptionBits(kIOHIDOptionsTypeNone)
    private let audioHaptics = DualSenseHaptics()
    var playedHaptics: Int { audioHaptics.playedBuffers }

    func intensity(trigger: Bool, value: UInt32) {
        queue.async { [self] in
            let change = driver.intensity(trigger: trigger, value: value)
            if change.stopsHaptics { audioHaptics.stop() }
            if let report = change.report { write(report) }
        }
    }

    func beginSession() {
        queue.async { [self] in driver.beginSession() }
    }
    func start() {
        queue.async { [self] in driver.start(); nextDeviceAttempt = .distantPast; findDevice() }
    }
    private func findDevice() {
        guard device == nil, Date() >= nextDeviceAttempt else { return }
        nextDeviceAttempt = Date().addingTimeInterval(1)
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, Self.noOptions)
        IOHIDManagerSetDeviceMatchingMultiple(manager, [0x0ce6, 0x0df2].map { [kIOHIDVendorIDKey: 0x054c, kIOHIDProductIDKey: $0, kIOHIDPrimaryUsagePageKey: 1, kIOHIDPrimaryUsageKey: 5] } as CFArray)
        guard IOHIDManagerOpen(manager, Self.noOptions) == kIOReturnSuccess else { return }
        self.manager = manager
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let device = devices.first else {
            forgetDevice()
            return
        }
        self.device = device
        driver.bluetooth = (IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String)?.lowercased().contains("bluetooth") == true
        for report in driver.greeting() { write(report) }
    }
    func send(_ report: DualSenseReport) {
        queue.async { [self] in
            guard let report = driver.send(report, now: DispatchTime.now().uptimeNanoseconds) else { return }
            findDevice(); write(report)
        }
    }
    private func write(_ report: DualSenseReport) {
        guard let device else { return }
        let report = driver.outgoing(report)
        let packet = report.packet(bluetooth: driver.bluetooth)
        let result = packet.withUnsafeBufferPointer { IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(packet[0]), $0.baseAddress!, packet.count) }
        driver.wrote(report, succeeded: result == kIOReturnSuccess)
        if result != kIOReturnSuccess {
            NSLog("Con DualSense: HID output failed (%d)", result)
            forgetDevice()
        }
    }
    private func forgetDevice() {
        device = nil
        if let manager { IOHIDManagerClose(manager, Self.noOptions) }
        manager = nil
    }
    func haptics(_ pcm: Data) {
        queue.async { [self] in
            guard driver.playsHaptics else { return }
            findDevice()
            if !driver.bluetooth, audioHaptics.submit(pcm) {
                if let report = driver.returnToHaptics { write(report) }
                return
            }
            guard let report = driver.rumble(for: pcm, now: DispatchTime.now().uptimeNanoseconds) else { return }
            let made = driver.lastRumble
            write(report)
            queue.asyncAfter(deadline: .now() + DualSenseDriver.rumbleLength) { [weak self] in
                guard let self, let idle = self.driver.rest(afterRumbleAt: made) else { return }
                self.write(idle)
            }
        }
    }
    func silence() {
        queue.async { [self] in
            guard let report = driver.silence() else { return }
            write(report)
            audioHaptics.stop()
        }
    }
    func stop(wait: Bool = false) {
        let work = { [self] in
            write(driver.stop())
            audioHaptics.stop()
            forgetDevice()
        }
        if wait { queue.sync(execute: work) } else { queue.async(execute: work) }
    }
}
