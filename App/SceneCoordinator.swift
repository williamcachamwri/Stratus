import AppKit
import os.log
import SwiftUI

// MARK: - WindowID

// Centralised string constants matching the `id:` parameters in StratusApp's
// WindowGroup / Settings scenes. Keeping them here avoids magic-string drift
// across call sites.

public enum WindowID {
    static let main = "main" // ContentView (upload center + file browser)
    static let preferences = "preferences" // PreferencesView via Settings scene
    static let fileBrowser = "file-browser" // Standalone FileBrowserView window
}

// MARK: - SceneCoordinator

// Coordinates window and scene lifecycle for the Stratus macOS app.
//
// Design notes:
// • Uses NSApp.sendAction(_:to:from:) for commands that have no SwiftUI
//   counterpart (e.g., opening the Settings/Preferences panel).
// • Uses NSApp window enumeration for showing / ordering named windows because
//   the SwiftUI `openWindow` environment action cannot be called outside a
//   View body. For Views, prefer injecting the `@Environment(\.openWindow)`
//   action directly rather than routing through this coordinator.
// • All methods are @MainActor to keep AppKit calls on the main thread.

@MainActor
public final class SceneCoordinator: ObservableObject {
    // MARK: - Singleton

    public static let shared = SceneCoordinator()

    // MARK: - Published State

    @Published public private(set) var focusedWindowID: String?

    // MARK: - Private

    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "SceneCoordinator")

    private init() {}

    // MARK: - Window Actions

    /// Brings the main window (Upload Center) to the front, activating the app.
    public func openUploadCenter() {
        activateApp()
        if let window = findWindow(id: WindowID.main) {
            window.makeKeyAndOrderFront(nil)
            focusedWindowID = WindowID.main
            logger.info("Opened Upload Center window")
        } else {
            // Window not yet created – ask SwiftUI to open it via the
            // Application menu's "Show All Windows" or equivalent trigger.
            // Fallback: activate app so the user can find it.
            logger.warning("Main window not found; falling back to app activation")
        }
    }

    /// Opens the Preferences / Settings panel via the standard AppKit mechanism.
    public func openPreferences() {
        activateApp()
        // NSApp.sendAction routes to the Settings scene registered by SwiftUI.
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        focusedWindowID = WindowID.preferences
        logger.info("Opened Preferences window")
    }

    /// Opens the standalone File Browser window.
    public func openFileBrowser() {
        activateApp()
        if let window = findWindow(id: WindowID.fileBrowser) {
            window.makeKeyAndOrderFront(nil)
            focusedWindowID = WindowID.fileBrowser
            logger.info("Opened File Browser window (existing)")
        } else {
            // Request SwiftUI to open the scene. Callers with access to the
            // SwiftUI environment should prefer `openWindow(id:)` directly.
            openWindowFallback(id: WindowID.fileBrowser)
        }
    }

    // MARK: - Helpers

    private func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Returns the first NSWindow whose identifier matches `id`.
    private func findWindow(id: String) -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == id }
    }

    /// Fallback for scene IDs that do not yet have an open NSWindow instance.
    /// Posts a notification that StratusApp can observe to trigger `openWindow`.
    private func openWindowFallback(id: String) {
        NotificationCenter.default.post(
            name: SceneCoordinator.openWindowNotification,
            object: nil,
            userInfo: [SceneCoordinator.windowIDKey: id]
        )
        logger.info("Posted openWindow notification for id: \(id)")
    }

    /// Updates the focused window ID from external callers (e.g. View extension).
    public func setFocused(windowID: String) {
        focusedWindowID = windowID
    }
}

// MARK: - Notification

public extension SceneCoordinator {
    /// Notification posted when a window needs to be opened via the SwiftUI
    /// `openWindow` environment action. StratusApp observes this.
    static let openWindowNotification = Notification.Name("com.stratus.openWindow")
    static let windowIDKey = "windowID"
}

// MARK: - View Extension (convenience)

public extension View {
    /// Opens a named window using the SwiftUI environment action, and updates
    /// SceneCoordinator focus state.
    func openStratusWindow(id: String, openWindow: OpenWindowAction) {
        openWindow(id: id)
        Task { @MainActor in
            SceneCoordinator.shared.setFocused(windowID: id)
        }
    }
}
