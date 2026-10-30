import Foundation
import SoleCore
import SoleEngine
import SoleLogic
#if canImport(Android)
import Android
#endif

private final class Box<Value>: @unchecked Sendable {
    var value: Value?
}

private func wait<Value: Sendable>(_ body: @escaping @Sendable () async -> Value) -> Value {
    let result = Box<Value>(), done = DispatchSemaphore(value: 0)
    Task.detached {
        result.value = await body()
        done.signal()
    }
    done.wait()
    return result.value!
}

private func answer(_ object: [String: Any]) -> UnsafeMutablePointer<CChar>? {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    return strdup(String(decoding: data, as: UTF8.self))
}

@_cdecl("con_start")
public func conStart(_ files: UnsafePointer<CChar>, _ caches: UnsafePointer<CChar>) -> Int32 {
    setenv("HOME", String(cString: files), 1)
    setenv("TMPDIR", String(cString: caches), 1)
    let folder = URL(fileURLWithPath: String(cString: caches))
    let roots = AndroidCertificates.install(in: folder)
    guard SoleEngine.initialize() else { return -1 }
    Task { @MainActor in
        if AndroidApp.shared == nil { AndroidApp.shared = AndroidApp(caches: folder) }
    }
    return Int32(roots)
}

@_cdecl("con_state")
public func conState() -> UnsafeMutablePointer<CChar>? { strdup(Picture.current) }

@_cdecl("con_login_finished")
public func conLoginFinished(_ address: UnsafePointer<CChar>, _ sentSecurely: UnsafePointer<CChar>, _ sentPlainly: UnsafePointer<CChar>) {
    let address = String(cString: address), secure = String(cString: sentSecurely), plain = String(cString: sentPlainly)
    Task { @MainActor in AndroidApp.shared?.page.reached(address, sentSecurely: secure, sentPlainly: plain) }
}
@_cdecl("con_login_closed")
public func conLoginClosed() { Task { @MainActor in AndroidApp.shared?.page.closed() } }

@_cdecl("con_act")
public func conAct(_ name: UnsafePointer<CChar>, _ value: UnsafePointer<CChar>) {
    let name = String(cString: name), value = String(cString: value)
    Task { @MainActor in AndroidApp.shared?.act(name, value) }
}

@_cdecl("con_ask")
public func conAsk(_ name: UnsafePointer<CChar>, _ value: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    let name = String(cString: name), value = String(cString: value)
    return wait {
        switch name {
        case "screenshots": return answer(["urls": await AndroidApp.screenshots(of: value)])
        default: return answer(["error": "unknown question"])
        }
    }
}

@_cdecl("con_pad")
public func conPad(_ buttons: Int32, _ l2: Float, _ r2: Float, _ leftX: Float, _ leftY: Float, _ rightX: Float, _ rightY: Float) {
    let order: [ControllerState.Button] = [.cross, .circle, .square, .triangle, .l1, .r1, .l3, .r3, .options, .share, .ps, .touchpad, .dpadUp, .dpadDown, .dpadLeft, .dpadRight]
    var reading = PadReading()
    for (bit, button) in order.enumerated() where buttons & (1 << Int32(bit)) != 0 { reading.buttons.insert(button) }
    reading.l2 = l2; reading.r2 = r2
    reading.leftX = leftX; reading.leftY = leftY; reading.rightX = rightX; reading.rightY = rightY
    Task { @MainActor in AndroidApp.shared?.take(reading) }
}
@_cdecl("con_pad_gone")
public func conPadGone() { Task { @MainActor in AndroidApp.shared?.take(nil) } }

@_cdecl("con_store_check")
public func conStoreCheck() -> Int32 {
    let record = Data("con-store-check".utf8)
    do {
        try AndroidCredentials.write(record, "check")
        guard try AndroidCredentials.read("check") == record else { return 1 }
        try AndroidCredentials.remove("check")
        return try AndroidCredentials.read("check") == nil ? 0 : 2
    } catch { return 3 }
}

@_cdecl("con_text")
public func conText(_ english: UnsafePointer<CChar>, _ language: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    strdup(Localization.text(String(cString: english), in: AppLanguage(rawValue: String(cString: language)) ?? .english))
}

@_cdecl("con_free")
public func conFree(_ text: UnsafeMutablePointer<CChar>?) { free(text) }
