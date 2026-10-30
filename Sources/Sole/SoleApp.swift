import SwiftUI
import AppKit
import Security
import SoleCore

@main struct SoleApp: App {
    @NSApplicationDelegateAdaptor(ConApplicationDelegate.self) private var applicationDelegate
    @Environment(\.openWindow) private var openWindow
    @StateObject private var model: SoleModel
    private static let probe = Data("dummy-credential-check".utf8)
    init() {
        SecKeychainSetUserInteractionAllowed(false)
        if let mode = CommandLine.arguments.first(where: { $0.hasPrefix("--credential-check-") }) {
            do {
                if mode == "--credential-check-write" {
                    _ = try CredentialAgent.perform("write", account: "probe", data: Self.probe)
                } else if mode == "--credential-check-read" {
                    guard try CredentialAgent.perform("read", account: "probe") == Self.probe else { exit(1) }
                    _ = try CredentialAgent.perform("remove", account: "probe")
                } else { exit(1) }
                print("Credential persistence check passed")
                exit(0)
            } catch { print("Credential check failed"); exit(1) }
        }
        _model = StateObject(wrappedValue: SoleModel())
    }
    var body: some Scene {
        Window("Con", id: "main") {
            SoleWindow().environmentObject(model).environmentObject(model.focus)
                .onAppear { applicationDelegate.reopenMainWindow = { openWindow(id: "main") } }
                .preferredColorScheme(.dark)
                .frame(minWidth: 620, minHeight: 520)
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button(loc("Settings…")) { model.showSettings() }.keyboardShortcut(",")
            }
        }
    }
}

@MainActor final class ConApplicationDelegate: NSObject, NSApplicationDelegate {
    var reopenMainWindow: (() -> Void)?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if let window = sender.windows.first(where: { $0.isMiniaturized }) {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        } else if !hasVisibleWindows {
            reopenMainWindow?()
        }
        return true
    }
}
