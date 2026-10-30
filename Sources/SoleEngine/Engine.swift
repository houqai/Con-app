import Foundation

public enum SoleEngine {
    public static var version: String { RustEngine.version }

    @discardableResult public static func initialize() -> Bool {
        RustEngine.prepare()
        return RustEngine.interfaceMatches
    }
}

public enum EngineError: Error, Sendable, Equatable {
    case engine(code: Int32, message: String)
    case invalidCredentials
    case cancelled
}
