import CConEngine
import CConPlatform
import Foundation

public final class ConsoleDiscovery {
    private let handler: @MainActor ([DiscoveredConsole]) -> Void
    private var handle: OpaquePointer?

    public init(onUpdate: @escaping @MainActor ([DiscoveredConsole]) -> Void) { handler = onUpdate }
    var isRunning: Bool { handle != nil }

    public func start() {
        guard handle == nil else { return }
        RustEngine.prepare()
        var config = ConDiscoveryConfig()
        _ = con_discovery_config_default(&config)
        config.initial_delay_ms = 500; config.period_ms = 500; config.drop_after_rounds = 3; config.max_consoles = 16
        let stride = 16, capacity = 32
        var buffer = [CChar](repeating: 0, count: stride * capacity)
        let count = buffer.withUnsafeMutableBufferPointer { con_broadcast_address_texts($0.baseAddress, stride, capacity) }
        let user = Unmanaged.passUnretained(self).toOpaque()
        var started: OpaquePointer?
        let code = buffer.withUnsafeBufferPointer { texts -> Int32 in
            let destinations: [UnsafePointer<CChar>?] = (0..<count).map { texts.baseAddress! + $0 * stride }
            return destinations.withUnsafeBufferPointer { list -> Int32 in
                config.extra_destinations = list.isEmpty ? nil : list.baseAddress
                config.extra_destination_count = list.count
                return con_discovery_start(&config, { user, hosts, count in
                    guard let user else { return }
                    let consoles = (0..<count).compactMap { index in hosts.map { RustMapping.console($0[index]) } }
                    let discovery = Unmanaged<ConsoleDiscovery>.fromOpaque(user).takeUnretainedValue()
                    DispatchQueue.main.async { [weak discovery] in
                        MainActor.assumeIsolated {
                            guard let discovery, discovery.isRunning else { return }
                            discovery.handler(consoles)
                        }
                    }
                }, user, &started)
            }
        }
        if code == CON_OK { handle = started }
    }

    public func stop() {
        guard let handle else { return }
        self.handle = nil
        con_discovery_stop(handle)
    }

    deinit { if let handle { con_discovery_stop(handle) } }
}
