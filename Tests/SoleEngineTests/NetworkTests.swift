import Testing
import Foundation
import CConPlatform
@testable import SoleEngine

final class SilentPort: @unchecked Sendable {
    struct Unavailable: Error {}
    let port: UInt16
    private let held: Int
    init() throws {
        var port: UInt16 = 0
        let held = con_test_udp_port_hold(&port)
        guard held >= 0, port != 0 else { throw Unavailable() }
        self.port = port; self.held = held
    }
    deinit { con_test_udp_port_release(held) }
}

@Suite struct BroadcastAddressTests {
    private func texts(stride: Int = 16, capacity: Int = 32) -> [String] {
        var buffer = [CChar](repeating: 0, count: max(1, stride * capacity))
        let count = buffer.withUnsafeMutableBufferPointer { con_broadcast_address_texts($0.baseAddress, stride, capacity) }
        return (0..<count).map { index in buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress! + index * stride) } }
    }

    @Test func theAddressesAreNumericTextEachOnce() {
        let found = texts()
        for text in found {
            let parts = text.split(separator: ".").compactMap { UInt8($0) }
            #expect(parts.count == 4, "\(text)")
            #expect(text != "127.255.255.255", "no loopback")
        }
        #expect(Set(found).count == found.count, "each network once")
    }
    @Test func neverMoreThanThereIsRoomFor() {
        #expect(texts(capacity: 0).isEmpty)
        #expect(texts(stride: 15).isEmpty, "a stride too small for an address")
        #expect(con_broadcast_address_texts(nil, 16, 4) == 0)
        if texts().count > 1 { #expect(texts(capacity: 1).count == 1) }
    }

    #if canImport(Darwin)
    @Test func theNetworksOfThisComputerAreFound() {
        var expected: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return }
        defer { freeifaddrs(list) }
        var next = list
        while let current = next {
            defer { next = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  let netmask = current.pointee.ifa_netmask,
                  (current.pointee.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
                  (current.pointee.ifa_flags & UInt32(IFF_BROADCAST)) != 0 else { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let text = withUnsafeBytes(of: ip | ~mask) { $0.map(String.init).joined(separator: ".") }
            if !expected.contains(text) { expected.append(text) }
        }
        #expect(texts() == expected)
    }
    #endif
}
