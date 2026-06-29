import AppKit
import os.log

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "AppDelegate")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        Task {
            await AppEnvironment.shared.syncScheduler.onAppLaunch()
        }
        logger.info("Stratus launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        logger.info("Stratus terminating")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false  // Keep running as a menu bar app after windows close
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
