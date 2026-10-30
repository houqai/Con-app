import Foundation
#if canImport(Android)
import Android
#endif

public enum AndroidCertificates {
    private static let folders = ["/apex/com.android.conscrypt/cacerts", "/system/etc/security/cacerts"]

    @discardableResult public static func install(in folder: URL) -> Int {
        var bundle = "", count = 0
        let listings = folders.lazy.map { (path: $0, names: (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? []) }
        guard let source = listings.first(where: { !$0.names.isEmpty }) else { return 0 }
        for name in source.names.sorted() {
            guard let data = FileManager.default.contents(atPath: source.path + "/" + name), let text = String(data: data, encoding: .utf8),
                  let begin = text.range(of: "-----BEGIN CERTIFICATE-----"), let end = text.range(of: "-----END CERTIFICATE-----"),
                  begin.lowerBound < end.lowerBound else { continue }
            bundle += text[begin.lowerBound..<end.upperBound] + "\n"
            count += 1
        }
        guard count > 0 else { return 0 }
        let file = folder.appendingPathComponent("root-certificates.pem")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(bundle.utf8).write(to: file, options: .atomic)
        } catch { return 0 }
        setenv("URLSessionCertificateAuthorityInfoFile", file.path, 1)
        return count
    }
}
