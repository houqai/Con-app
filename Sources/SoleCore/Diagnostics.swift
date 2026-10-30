import Foundation

public enum Diagnostics {
    public static let cachesDirectory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Sole/diagnostics", isDirectory: true)

    public static let testDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("con-test-diagnostics", isDirectory: true)

    public static let directory: URL? = runsTests(processName: ProcessInfo.processInfo.processName, bundles: Bundle.allBundles.map(\.bundlePath))
        ? testDirectory : cachesDirectory

    public static func write(_ object: Any, named name: String) {
        guard let target = directory,
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try? data.write(to: target.appendingPathComponent(name), options: .atomic)
    }

    public static func runsTests(processName: String, bundles: [String]) -> Bool {
        ["xctest", "swiftpm-testing-helper"].contains(processName) || processName.hasPrefix("ConPackageTests")
            || bundles.contains { $0.hasSuffix(".xctest") }
    }
}
