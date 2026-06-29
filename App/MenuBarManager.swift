import AppKit
import SwiftUI
import StratusCore
import os.log

// MARK: - MenuBarManager
// Manages the NSStatusItem in the system menu bar, displaying the current upload
// speed as a text label that updates every second. The full interactive popover
// is handled by the MenuBarExtra scene in StratusApp; this class provides the
// lightweight NSStatusBar integration layer for always-visible speed feedback.

@MainActor
final class MenuBarManager: ObservableObject {

    // MARK: - Published State

    @Published private(set) var currentBPS: Double = 0

    // MARK: - Private

    private let statusItem: NSStatusItem
    private let bandwidthMonitor: BandwidthMonitor
    private var tickTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "MenuBarManager")

    // MARK: - Init / Deinit

    init(bandwidthMonitor: BandwidthMonitor = BandwidthMonitor()) {
        self.bandwidthMonitor = bandwidthMonitor
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureButton()
        startTicker()
        startBandwidthListener()
    }

    deinit {
        tickTask?.cancel()
        snapshotTask?.cancel()
        // NSStatusItem cleanup skipped: MenuBarManager is a process-lifetime singleton.
        // Calling removeStatusItem from a nonisolated deinit would require crossing the
        // main-actor boundary for a non-Sendable NSStatusItem, which Swift 6 disallows.
    }

    // MARK: - Visibility

    func show() {
        statusItem.isVisible = true
    }

    func hide() {
        statusItem.isVisible = false
    }

    // MARK: - Private Setup

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "icloud.and.arrow.up", accessibilityDescription: "Stratus")
        button.image?.isTemplate = true
        button.imagePosition = .imageLeft
        button.title = ""
        button.toolTip = "Stratus – Cloud Drive Manager"
    }

    /// Updates the visible label once per second from the cached `currentBPS` value.
    private func startTicker() {
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.refreshLabel()
            }
        }
    }

    /// Subscribes to the BandwidthMonitor stream for smooth snapshot updates.
    private func startBandwidthListener() {
        snapshotTask = Task { [weak self] in
            guard let self else { return }
            for await snapshot in await self.bandwidthMonitor.updates {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.currentBPS = snapshot.currentBPS
                }
            }
        }
    }

    @MainActor
    private func refreshLabel() {
        guard let button = statusItem.button else { return }
        if currentBPS > 0 {
            button.title = " \(formattedSpeed(currentBPS))"
        } else {
            button.title = ""
        }
        logger.debug("MenuBar speed label updated: \(self.currentBPS, format: .fixed(precision: 0)) B/s")
    }

    // MARK: - Formatting

    private func formattedSpeed(_ bps: Double) -> String {
        switch bps {
        case ..<1_024:
            return String(format: "%.0f B/s", bps)
        case ..<(1_024 * 1_024):
            return String(format: "%.1f KB/s", bps / 1_024)
        case ..<(1_024 * 1_024 * 1_024):
            return String(format: "%.1f MB/s", bps / (1_024 * 1_024))
        default:
            return String(format: "%.1f GB/s", bps / (1_024 * 1_024 * 1_024))
        }
    }
}
