import AppKit
import os.log

// MARK: - DockProgressManager
// Updates the Dock tile with overall upload progress and badge count for pending conflicts.

@MainActor
public final class DockProgressManager: NSObject, ObservableObject {
    public static let shared = DockProgressManager()
    private let dockTile = NSApp.dockTile
    private var progressView: DockProgressView?
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "DockProgress")

    private override init() {
        super.init()
        setupDockTile()
    }

    // MARK: - Setup

    private func setupDockTile() {
        let view = DockProgressView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
        dockTile.contentView = view
        progressView = view
        dockTile.display()
    }

    // MARK: - Update Progress

    public func updateUploadProgress(_ progress: Double, activeCount: Int) {
        progressView?.progress = progress
        progressView?.activeCount = activeCount
        dockTile.display()

        if activeCount == 0 {
            dockTile.badgeLabel = nil
        } else {
            dockTile.badgeLabel = "\(activeCount)"
        }
        logger.debug("Dock: \(String(format: "%.0f%%", progress * 100)) progress, \(activeCount) active")
    }

    public func updateConflictBadge(_ count: Int) {
        dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        dockTile.display()
    }

    public func clearProgress() {
        progressView?.progress = 0
        progressView?.activeCount = 0
        dockTile.badgeLabel = nil
        dockTile.display()
    }
}

// MARK: - DockProgressView

private final class DockProgressView: NSView {
    var progress: Double = 0
    var activeCount: Int = 0

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Draw the app icon
        if let appIcon = NSApp.applicationIconImage {
            appIcon.draw(in: bounds)
        }

        guard activeCount > 0, progress > 0 else { return }

        // Draw a progress bar at the bottom of the dock tile
        let barHeight: CGFloat = 14
        let padding: CGFloat = 6
        let barRect = NSRect(x: padding, y: padding, width: bounds.width - padding * 2, height: barHeight)

        // Background track
        NSColor.black.withAlphaComponent(0.5).setFill()
        let trackPath = NSBezierPath(roundedRect: barRect, xRadius: barHeight / 2, yRadius: barHeight / 2)
        trackPath.fill()

        // Progress fill
        let fillWidth = max(barHeight, (bounds.width - padding * 2) * progress)
        let fillRect = NSRect(x: padding, y: padding, width: fillWidth, height: barHeight)
        NSColor.systemGreen.setFill()
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: barHeight / 2, yRadius: barHeight / 2)
        fillPath.fill()
    }
}
