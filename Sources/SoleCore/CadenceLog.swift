import Foundation

public struct CadenceLog {
    static let kept = 1200
    private var entries: [String] = []
    private var sinceWritten = 0
    private let file: URL?

    public init(directory: URL?) { file = directory?.appendingPathComponent("cadence.txt") }

    public mutating func add(change: Double, new: Bool) {
        entries.append(String(format: "%.2f%@", change, new ? "N" : "."))
        if entries.count > Self.kept { entries.removeFirst(entries.count - Self.kept) }
        sinceWritten += 1
        guard sinceWritten >= Self.kept / 2, let file else { return }
        sinceWritten = 0
        let text = Self.text(entries)
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: file, options: .atomic)
        }
    }

    static func text(_ entries: [String]) -> String {
        stride(from: 0, to: entries.count, by: 20).map { entries[$0..<min($0 + 20, entries.count)].joined(separator: " ") }.joined(separator: "\n") + "\n"
    }
}
