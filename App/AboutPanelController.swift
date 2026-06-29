import AppKit
import SwiftUI

@MainActor
final class AboutPanelController {
    static let shared = AboutPanelController()

    private var window: NSWindow?

    private init() {}

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let content = AboutStratusView(
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0",
            build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev",
            closeAction: { [weak self] in self?.window?.close() }
        )
        let hostingController = NSHostingController(rootView: content)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "About Stratus"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.contentViewController = hostingController
        panel.center()
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace]
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        self.window = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
}

private struct AboutStratusView: View {
    let version: String
    let build: String
    let closeAction: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "icloud.and.arrow.up")
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(.primary)
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text("Stratus")
                    .font(.title2.weight(.semibold))
                Text("Native macOS Cloud Drive Manager")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                AboutInfoRow(label: "Version", value: "\(version) (\(build))")
                AboutInfoRow(label: "Bundle ID", value: Bundle.main.bundleIdentifier ?? "com.stratus.cloudmanager")
                AboutInfoRow(label: "Runtime", value: "Unsigned open-source build")
                AboutInfoRow(label: "Updates", value: "Sparkle direct release channel")
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text("Every file, every time, as fast as your internet allows.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button("Acknowledgements") {
                    if let url = URL(string: "https://github.com/sparkle-project/Sparkle") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Close", action: closeAction)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420, height: 360)
    }
}

private struct AboutInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}
