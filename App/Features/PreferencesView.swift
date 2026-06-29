import SwiftUI
import CryptoKit
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
    @AppStorage("encryptionEnabled") private var encryptionEnabled = false
    @AppStorage("encryptionPasswordSet") private var passwordIsSet = false
    @State private var password = ""
    @State private var confirm = ""
    @State private var isSaving = false
    @State private var feedback: Feedback?

    private enum Feedback {
        case success(String), failure(String)
    }

    var body: some View {
        Form {
            Toggle("Enable client-side encryption", isOn: $encryptionEnabled)
            if encryptionEnabled {
                SecureField("Master password", text: $password)
                SecureField("Confirm password", text: $confirm)
                Button(isSaving ? "Saving…" : (passwordIsSet ? "Update Master Password" : "Set Master Password")) {
                    Task { await saveMasterPassword() }
                }
                .disabled(password.isEmpty || password != confirm || isSaving)
                switch feedback {
                case .success(let msg):
                    Label(msg, systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                case .failure(let msg):
                    Label(msg, systemImage: "xmark.circle.fill")
                        .foregroundColor(.red)
                case nil:
                    EmptyView()
                }
            }
            Text("Files are encrypted with AES-256-GCM before upload. Your password never leaves this device.")
                .font(.stratusCaption)
                .foregroundColor(.textSecondary)
        }
        .padding(Spacing.lg)
    }

    private func saveMasterPassword() async {
        isSaving = true
        feedback = nil
        defer { isSaving = false }
        do {
            let salt = try EncryptionKeyDerivation.generateSalt()
            let masterKey = try EncryptionKeyDerivation.deriveKey(password: password, salt: salt)
            try await KeychainStore.shared.saveSecret(
                salt,
                service: "com.stratus.encryption.master",
                account: "salt"
            )
            // Wrap a sentinel key so the password can be verified on next unlock
            let sentinelKey = SymmetricKey(size: .bits256)
            let wrapped = try EncryptionKeyDerivation.wrapKey(sentinelKey, with: masterKey)
            try await KeychainStore.shared.saveSecret(
                wrapped,
                service: "com.stratus.encryption.master",
                account: "verification"
            )
            passwordIsSet = true
            password = ""
            confirm = ""
            feedback = .success("Master password saved.")
        } catch {
            feedback = .failure(error.localizedDescription)
        }
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
