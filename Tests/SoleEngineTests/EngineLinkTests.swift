import Testing
import Foundation
@testable import SoleEngine

@Suite struct ControllerMappingTests {
    @Test func idleStateIsZero() {
        let state = ControllerState.idle
        #expect(state.raw.buttons == 0)
        #expect(state.raw.leftX == 0 && state.raw.rightY == 0)
        #expect(state.raw.l2 == 0 && state.raw.r2 == 0)
        #expect(state.raw.touches.0.id == -1 && state.raw.touches.1.id == -1, "no finger")
        #expect(state.raw.accelY == 1 && state.raw.orientW == 1, "flat at rest")
    }
    @Test func buttonsAndAxesMap() {
        var state = ControllerState()
        state.setButtons([.cross, .r1, .options])
        state.setTriggers(l2: 1.0, r2: 0.5)
        state.setSticks(leftX: 1.0, leftY: 1.0, rightX: -1.0, rightY: 0.0)
        #expect(state.raw.buttons == 1 << 0 | 1 << 9 | 1 << 12)
        #expect(state.raw.l2 == 255)
        #expect(state.raw.r2 == 127)
        #expect(state.raw.leftX == 32767)
        #expect(state.raw.leftY == -32767)
        #expect(state.raw.rightX == -32767)
    }
    @Test func releasesBrakeWhileGasRemainsPressed() {
        var state = ControllerState()
        state.setButtons([.cross, .l1]); state.setTriggers(l2: 1, r2: 0)
        state.setButtons([]); state.setTriggers(l2: 0, r2: 1)
        #expect(state.raw.buttons == 0)
        #expect(state.raw.l2 == 0 && state.raw.r2 == 255)
        state.setTriggers(l2: 0.008, r2: .nan)
        #expect(state.raw.l2 == 0 && state.raw.r2 == 0)
    }
    @Test func twoFingersRetainIDsAndReleaseIndependently() {
        var state = ControllerState()
        state.setTouch(slot: 0, id: 7, x: -1, y: 1)
        state.setTouch(slot: 1, id: 8, x: 1, y: -1)
        #expect(state.raw.touches.0.id == 7 && state.raw.touches.1.id == 8)
        #expect(state.raw.touches.0.x == 0 && state.raw.touches.0.y == 0)
        #expect(state.raw.touches.1.x == 1919 && state.raw.touches.1.y == 1079)
        state.setTouch(slot: 0, id: nil)
        #expect(state.raw.touches.0.id == -1 && state.raw.touches.1.id == 8)
    }
}

@Suite struct CredentialsTests {
    @Test func roundTripsThroughCodable() throws {
        let original = RemotePlayCredentials(registKey: Array(0..<16), morning: Array(16..<32), targetValue: ConsoleTarget.ps5v1.rawValue, serverMAC: [1,2,3,4,5,6], consolePIN: 12345678)
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(RemotePlayCredentials.self, from: data)
        #expect(restored == original)
        #expect(restored.isPS5)
        #expect(restored.valid)
    }
    @Test func rejectsWrongLengthKeys() {
        let bad = RemotePlayCredentials(registKey: [1,2,3], morning: Array(0..<16), targetValue: ConsoleTarget.ps4v10.rawValue, serverMAC: [], consolePIN: 0)
        #expect(!bad.valid)
        #expect(!bad.isPS5)
    }
    @Test func theStoredNumbersOfConsolesAreKept() throws {
        #expect(ConsoleTarget.allCases.map(\.rawValue) == [0, 800, 900, 1000, 1_000_000, 1_000_100])
        let stored = #"{"registKey":[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16],"morning":[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16],"targetValue":1000100,"serverMAC":[1,2,3,4,5,6],"consolePIN":12345678}"#
        let restored = try JSONDecoder().decode(RemotePlayCredentials.self, from: Data(stored.utf8))
        #expect(restored.isPS5 && restored.valid && restored.targetValue == ConsoleTarget.ps5v1.rawValue)
    }
}

@Suite struct CloudSessionInitTests {
    private func slot(key: Int = 16, specification: String = "launch-spec", sessionID: String = "cloud-session-1", port: UInt16 = 2053) -> CloudStreamSlot {
        CloudStreamSlot(host: "192.0.2.10", port: port, packetPrefix: 123, launchSpecification: specification, sessionID: sessionID,
                        handshakeKey: Data(repeating: 7, count: key), mtuIn: 1454, mtuOut: 1254, rttMs: 30)
    }
    private func open(_ slot: CloudStreamSlot) throws -> RemotePlaySession {
        try RemotePlaySession(cloud: slot, onVideo: { _, _, _, _, _ in true }, onEvent: { _ in })
    }
    @Test func acceptsAllocatedSlotWithoutConnecting() throws {
        _ = try open(slot())
    }
    @Test func acceptsPS4CloudSlotWithoutConnecting() throws {
        var ps4 = slot()
        ps4.isPS5 = false
        _ = try open(ps4)
    }
    @Test func aPS4SlotReportsHalfTheLossLimitOfAPS5Slot() {
        var ps4 = slot()
        ps4.isPS5 = false
        #expect(slot().reportedLossLimit == 0.04)
        #expect(ps4.reportedLossLimit == 0.02)
    }
    @Test func rejectsIncompleteSlots() {
        for bad in [slot(key: 15), slot(specification: ""), slot(sessionID: ""), slot(sessionID: String(repeating: "a", count: 128)), slot(port: 0)] {
            #expect(throws: EngineError.self) { _ = try open(bad) }
        }
    }
}
