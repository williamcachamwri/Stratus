import SwiftUI
import StratusCore
import AppKit

@main
struct StratusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var env = AppEnvironment.shared

    var body: some Scene {
        WindowGroup("Stratus", id: "main") {
            ContentView()
                .environmentObject(env)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("About Stratus") {
                    AboutPanelController.shared.show()
                }
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    env.appUpdater.checkForUpdates()
                }
            }
            CommandMenu("Sync") {
                Button("Sync All Now") {
                    Task { await env.syncEngine.syncAll() }
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra("Stratus", systemImage: "icloud.and.arrow.up") {
            MenuBarView()
                .environmentObject(env)
        }
        .menuBarExtraStyle(.window)

        Settings {
            PreferencesView()
                .environmentObject(env)
        }
    }
}
