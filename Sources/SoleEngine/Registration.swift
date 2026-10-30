import CConEngine
import Foundation

public final class RemotePlayRegistration {
    private final class Waiter {
        let pin: UInt32
        var continuation: CheckedContinuation<RemotePlayCredentials, Error>?
        init(pin: UInt32) { self.pin = pin }
    }
    private let lock = NSLock()
    private var handle: OpaquePointer?
    private var used = false

    public init() {}

    public func register(host: String, targetValue: UInt32, psnAccountID: [UInt8], pin: UInt32) async throws -> RemotePlayCredentials {
        guard psnAccountID.count == 8 else { throw EngineError.invalidCredentials }
        let first = lock.withLock { () -> Bool in
            guard !used else { return false }
            used = true
            return true
        }
        guard first else { throw EngineError.cancelled }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RemotePlayCredentials, Error>) in
            let waiter = Waiter(pin: pin)
            waiter.continuation = continuation
            RustEngine.prepare()
            var request = ConRegistrationRequest()
            _ = con_registration_request_default(&request)
            request.target = RustMapping.engineTarget(stored: targetValue)
            request.online_id = nil
            RustMapping.copy(psnAccountID, into: &request.account_id)
            let user = Unmanaged.passRetained(waiter).toOpaque()
            var started: OpaquePointer?
            let code = host.withCString { host in
                RustMapping.pinText(pin).withCString { pin in
                    request.host = host
                    request.pin = pin
                    return con_registration_start(&request, { user, result in
                        guard let user else { return }
                        let waiter = Unmanaged<Waiter>.fromOpaque(user).takeRetainedValue()
                        let outcome: Result<RemotePlayCredentials, EngineError> = result.map { RustMapping.credentials($0.pointee, pin: waiter.pin) } ?? .failure(.invalidCredentials)
                        let continuation = waiter.continuation
                        waiter.continuation = nil
                        continuation?.resume(with: outcome.mapError { $0 as Error })
                    }, user, &started)
                }
            }
            guard code == CON_OK else {
                Unmanaged<Waiter>.fromOpaque(user).release()
                continuation.resume(throwing: RustEngine.error(code))
                return
            }
            handle = started
        }
    }

    deinit {
        if let handle { con_registration_free(handle) }
    }
}
