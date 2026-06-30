import AppKit
import Foundation
import os.log
import StratusCore
import UserNotifications

// MARK: - StratusNotificationCenter

// Manages user-facing notifications for upload completion, failures, and sync conflicts.

@MainActor
public final class StratusNotificationCenter: ObservableObject {
    public static let shared = StratusNotificationCenter()
    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "Notifications")

    private init() {}

    // MARK: - Permission

    public func requestAuthorization() async {
        guard let center else { return }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            logger.info("Notification permission granted: \(granted)")
        } catch {
            logger.error("Notification permission request failed: \(error)")
        }
    }

    // MARK: - Upload Notifications

    public func notifyUploadComplete(fileName: String, providerName: String) {
        guard UserDefaults.standard.bool(forKey: "notifyUploadComplete") else { return }
        let content = UNMutableNotificationContent()
        content.title = "Upload Complete"
        content.body = "\(fileName) uploaded to \(providerName)"
        content.sound = .default
        content.categoryIdentifier = "UPLOAD_COMPLETE"
        schedule(content: content, id: "upload_complete_\(fileName)_\(Date().timeIntervalSince1970)")
    }

    public func notifyUploadFailed(fileName: String, error: String) {
        guard UserDefaults.standard.bool(forKey: "notifyUploadFailed") else { return }
        let content = UNMutableNotificationContent()
        content.title = "Upload Failed"
        content.body = "\(fileName): \(error)"
        content.sound = .defaultCritical
        content.categoryIdentifier = "UPLOAD_FAILED"
        // Add a "Retry" action
        content.userInfo = ["fileName": fileName]
        schedule(content: content, id: "upload_failed_\(fileName)")
    }

    // MARK: - Sync Notifications

    public func notifySyncConflict(fileName: String, pairID: UUID) {
        guard UserDefaults.standard.bool(forKey: "notifySyncConflict") else { return }
        let content = UNMutableNotificationContent()
        content.title = "Sync Conflict"
        content.body = "\(fileName) was modified both locally and remotely"
        content.sound = .default
        content.categoryIdentifier = "SYNC_CONFLICT"
        content.userInfo = ["pairID": pairID.uuidString, "fileName": fileName]
        schedule(content: content, id: "conflict_\(pairID)_\(fileName)")
    }

    public func notifySyncComplete(pairName: String, uploaded: Int, downloaded: Int) {
        guard uploaded + downloaded > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = "Sync Complete — \(pairName)"
        var parts: [String] = []
        if uploaded > 0 { parts.append("\(uploaded) uploaded") }
        if downloaded > 0 { parts.append("\(downloaded) downloaded") }
        content.body = parts.joined(separator: ", ")
        content.sound = .default
        schedule(content: content, id: "sync_complete_\(pairName)")
    }

    // MARK: - Register Notification Categories

    public func registerCategories() {
        guard let center else { return }
        let retryAction = UNNotificationAction(identifier: "RETRY", title: "Retry", options: [])
        let openAction = UNNotificationAction(identifier: "OPEN", title: "Open Stratus", options: [.foreground])
        let resolveAction = UNNotificationAction(identifier: "RESOLVE", title: "Resolve", options: [.foreground])

        let uploadFailedCategory = UNNotificationCategory(
            identifier: "UPLOAD_FAILED",
            actions: [retryAction, openAction],
            intentIdentifiers: [],
            options: []
        )
        let conflictCategory = UNNotificationCategory(
            identifier: "SYNC_CONFLICT",
            actions: [resolveAction, openAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([uploadFailedCategory, conflictCategory])
    }

    // MARK: - Private

    private func schedule(content: UNMutableNotificationContent, id: String) {
        guard let center else { return }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        center.add(request) { [weak self] error in
            if let error { self?.logger.error("Failed to schedule notification \(id): \(error)") }
        }
    }
}
