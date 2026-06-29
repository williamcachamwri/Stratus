import SwiftUI
import StratusCore

public struct VaultSetupFlow: View {
    @State private var selectedMode: VaultMode = .stratusNative
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var enableBiometricUnlock = true

    public init() {}

    public var body: some View {
        Form {
            Section("Vault Format") {
                Picker("Format", selection: $selectedMode) {
                    ForEach(VaultMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(selectedMode.detail)
                    .stratusCaption()
            }

            Section("Encryption Key") {
                SecureField("Vault password", text: $password)
                SecureField("Confirm password", text: $confirmPassword)
                Toggle("Allow Touch ID / Apple Watch unlock", isOn: $enableBiometricUnlock)
            }

            Section("Pipeline") {
                EncryptionPipelinePreview(mode: selectedMode)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Create Encrypted Vault")
        .toolbar {
            Button("Create Vault") {}
                .disabled(!canCreateVault)
        }
    }

    private var canCreateVault: Bool {
        password.count >= 12 && password == confirmPassword
    }
}

public enum VaultMode: String, CaseIterable, Identifiable, Sendable {
    case stratusNative
    case cryptomatorCompatible

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .stratusNative: return "Stratus Native"
        case .cryptomatorCompatible: return "Cryptomator"
        }
    }

    public var detail: String {
        switch self {
        case .stratusNative:
            return "AES-256-GCM per chunk with encrypted manifest metadata."
        case .cryptomatorCompatible:
            return "Interoperable vault layout for users who need external readers."
        }
    }
}

private struct EncryptionPipelinePreview: View {
    let mode: VaultMode

    private let stages = [
        "Read chunk",
        "Hash plaintext",
        "Encrypt AES-GCM",
        "Upload ciphertext",
        "Verify encrypted checksum",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ForEach(Array(stages.enumerated()), id: \.offset) { index, title in
                HStack(spacing: Spacing.sm) {
                    Text("\(index + 1)")
                        .font(.stratusSmallMono)
                        .foregroundColor(.textSecondary)
                        .frame(width: 20, alignment: .trailing)
                    Text(title)
                        .font(.stratusBody)
                    Spacer()
                }
            }
            Text(mode.detail)
                .stratusCaption()
        }
        .padding(.vertical, Spacing.xs)
    }
}
