import Foundation

enum ProjectSources {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static var available: Bool {
        #if os(Windows)
        return false
        #else
        return FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources/SoleCore").path)
        #endif
    }
    static let missing = "Project sources are not available"

    static func swiftFiles(in directory: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(directory), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    }
}
