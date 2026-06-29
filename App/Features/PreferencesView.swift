import SwiftUI
import StratusCore

struct PreferencesView: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        TabView {
            GeneralPrefsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            BandwidthPrefsTab()
                .tabItem { Label("Bandwidth", systemImage: "speedometer") }
            EncryptionPrefsTab()
                .tabItem { Label("Encryption", systemImage: "lock.shield") }
            NotificationsPrefsTab()
                .tabItem { Label("Notifications", systemImage: "bell") }
        }
        .padding(Spacing.xl)
        .frame(width: 520, height: 380)
    }
}

// MARK: - General Prefs

private struct GeneralPrefsTab: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showDockIcon") private var showDockIcon = true
    @AppStorage("updateChannel") private var updateChannel = "stable"

    var body: some View {
        Form {
            Toggle("Launch at login", isOn: $launchAtLogin)
            Toggle("Show Dock icon", isOn: $showDockIcon)
            Picker("Update channel", selection: $updateChannel) {
                Text("Stable").tag("stable")
                Text("Beta").tag("beta")
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
        }
        .padding(Spacing.lg)
    }
}

// MARK: - Bandwidth Prefs

private struct BandwidthPrefsTab: View {
    @AppStorage("uploadLimitMBps") private var uploadLimit: Double = 100
    @AppStorage("downloadLimitMBps") private var downloadLimit: Double = 100

    var body: some View {
        Form {
            LabeledContent("Upload limit:") {
                BandwidthSlider(limitMBps: $uploadLimit, range: 1...500)
            }
            LabeledContent("Download limit:") {
                BandwidthSlider(limitMBps: $downloadLimit, range: 1...500)
            }
            Section("Schedule") {
                Text("Bandwidth scheduling available per sync pair")
                    .foregroundColor(.textSecondary)
                    .font(.stratusCaption)
            }
        }
        .padding(Spacing.lg)
    }
}

// MARK: - Encryption Prefs

private struct EncryptionPrefsTab: View {
    @State private var password = ""
    @State private var confirm = ""
    @State private var encryptionEnabled = false

    var body: some View {
        Form {
            Toggle("Enable client-side encryption", isOn: $encryptionEnabled)
            if encryptionEnabled {
                SecureField("Master password", text: $password)
                SecureField("Confirm password", text: $confirm)
                Button("Set Master Password") {
                    // Derive and store key in Keychain
                }
                .disabled(password.isEmpty || password != confirm)
            }
            Text("Files are encrypted with AES-256-GCM before upload. Your password never leaves this device.")
                .font(.stratusCaption)
                .foregroundColor(.textSecondary)
        }
        .padding(Spacing.lg)
    }
}

// MARK: - Notifications Prefs

private struct NotificationsPrefsTab: View {
    @AppStorage("notifyUploadComplete") private var notifyComplete = true
    @AppStorage("notifyUploadFailed") private var notifyFailed = true
    @AppStorage("notifySyncConflict") private var notifyConflict = true

    var body: some View {
        Form {
            Toggle("Upload completed", isOn: $notifyComplete)
            Toggle("Upload failed", isOn: $notifyFailed)
            Toggle("Sync conflict detected", isOn: $notifyConflict)
        }
        .padding(Spacing.lg)
    }
}
