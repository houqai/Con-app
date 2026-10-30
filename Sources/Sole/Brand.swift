import AppKit
import SoleLogic

@MainActor enum ConBrand {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ConVersion.number }
    static let icon: NSImage = NSWorkspace.shared.icon(forFile: Bundle.main.bundleURL.path)
}
