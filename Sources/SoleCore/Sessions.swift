import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension URLSession {
    public static func lasting(_ configuration: URLSessionConfiguration, delegate: URLSessionDelegate? = nil) -> URLSession {
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        #if !canImport(Darwin)
        KeptSessions.shared.add(session)
        #endif
        return session
    }
}

#if !canImport(Darwin)
private final class KeptSessions: @unchecked Sendable {
    static let shared = KeptSessions()
    private let lock = NSLock()
    private var sessions: [URLSession] = []
    func add(_ session: URLSession) { lock.lock(); sessions.append(session); lock.unlock() }
}
#endif
