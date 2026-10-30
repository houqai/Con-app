import Foundation
import Security

enum CredentialAgent {
    private struct Request: Codable { let operation: String; let account: String; let data: Data? }
    private struct Reply: Codable { let status: Int32; let data: Data? }
    enum Failure: Error { case unavailable, denied(Int32) }
    static func perform(_ operation: String, account: String, data: Data? = nil) throws -> Data? {
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/SoleCredentialAgent")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw Failure.unavailable }
        let process = Process(); process.executableURL = executable
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(try JSONEncoder().encode(Request(operation: operation, account: account, data: data)))
        try input.fileHandleForWriting.close()
        let encoded = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard encoded.count < 1_500_000, let result = try? JSONDecoder().decode(Reply.self, from: encoded) else { throw Failure.unavailable }
        if result.status == errSecItemNotFound { return nil }
        guard result.status == errSecSuccess else { throw Failure.denied(result.status) }
        return result.data
    }
}
