import Foundation

public enum Settings {
    nonisolated(unsafe) public static var store: UserDefaults = {
        #if os(Windows)
        let data = ProcessInfo.processInfo.environment["APPDATA"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let program = ProcessInfo.processInfo.processName.replacingOccurrences(of: ".exe", with: "", options: [.caseInsensitive, .anchored, .backwards])
        return FileDefaults(file: data.appendingPathComponent("app.sole.desktop", isDirectory: true).appendingPathComponent(program + ".plist"))
        #else
        return .standard
        #endif
    }()
}

public final class FileDefaults: UserDefaults {
    private let file: URL
    private let lock = NSLock()
    private var values: [String: Any]
    private var registered: [String: Any] = [:]

    public init(file: URL) {
        self.file = file
        let data = try? Data(contentsOf: file)
        values = data.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
        super.init(suiteName: nil)!
    }

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    private func save() {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    public override func object(forKey defaultName: String) -> Any? { locked { values[defaultName] ?? registered[defaultName] } }

    public override func set(_ value: Any?, forKey defaultName: String) {
        locked {
            if let value { values[defaultName] = value } else { values.removeValue(forKey: defaultName) }
            save()
        }
    }
    public override func removeObject(forKey defaultName: String) { set(nil as Any?, forKey: defaultName) }
    public override func register(defaults registrationDictionary: [String: Any]) { locked { registered.merge(registrationDictionary) { $1 } } }
    public override func dictionaryRepresentation() -> [String: Any] { locked { registered.merging(values) { $1 } } }
    public override func synchronize() -> Bool { true }

    public override func set(_ value: Int, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
    public override func set(_ value: Double, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
    public override func set(_ value: Float, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
    public override func set(_ value: Bool, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
    public override func set(_ url: URL?, forKey defaultName: String) { set(url?.absoluteString as Any?, forKey: defaultName) }
    public override func string(forKey defaultName: String) -> String? { object(forKey: defaultName) as? String }
    public override func data(forKey defaultName: String) -> Data? { object(forKey: defaultName) as? Data }
    public override func array(forKey defaultName: String) -> [Any]? { object(forKey: defaultName) as? [Any] }
    public override func stringArray(forKey defaultName: String) -> [String]? { object(forKey: defaultName) as? [String] }
    public override func dictionary(forKey defaultName: String) -> [String: Any]? { object(forKey: defaultName) as? [String: Any] }
    public override func url(forKey defaultName: String) -> URL? { string(forKey: defaultName).flatMap(URL.init(string:)) }
    public override func integer(forKey defaultName: String) -> Int { number(defaultName)?.intValue ?? Int(string(forKey: defaultName) ?? "") ?? 0 }
    public override func double(forKey defaultName: String) -> Double { number(defaultName)?.doubleValue ?? Double(string(forKey: defaultName) ?? "") ?? 0 }
    public override func float(forKey defaultName: String) -> Float { Float(double(forKey: defaultName)) }
    public override func bool(forKey defaultName: String) -> Bool {
        if let number = number(defaultName) { return number.boolValue }
        return ["yes", "true", "1"].contains(string(forKey: defaultName)?.lowercased() ?? "")
    }
    private func number(_ key: String) -> NSNumber? {
        switch object(forKey: key) {
        case let value as Bool: return NSNumber(value: value)
        case let value as Int: return NSNumber(value: value)
        case let value as Double: return NSNumber(value: value)
        case let value as NSNumber: return value
        default: return nil
        }
    }
}
