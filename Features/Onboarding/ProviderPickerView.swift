import SwiftUI
import StratusCore

public struct ProviderPickerView: View {
    public let providers: [ProviderChoice]
    public var onSelect: (ProviderChoice) -> Void

    public init(
        providers: [ProviderChoice] = ProviderChoice.builtIn,
        onSelect: @escaping (ProviderChoice) -> Void = { _ in }
    ) {
        self.providers = providers
        self.onSelect = onSelect
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Connect a Cloud Account")
                    .font(.stratusTitle)
                Text("Choose a provider. Stratus will show only capabilities supported by that backend.")
                    .stratusCaption()
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: Spacing.md)], spacing: Spacing.md) {
                ForEach(providers) { provider in
                    Button {
                        onSelect(provider)
                    } label: {
                        ProviderChoiceCard(provider: provider)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(Spacing.xl)
        .background(Color.surfaceSecondary)
    }
}

public struct ProviderChoice: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let supportsParallelChunks: Bool
    public let supportsMounting: Bool

    public init(
        id: String,
        title: String,
        subtitle: String,
        supportsParallelChunks: Bool,
        supportsMounting: Bool
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.supportsParallelChunks = supportsParallelChunks
        self.supportsMounting = supportsMounting
    }

    public static let builtIn: [ProviderChoice] = [
        ProviderChoice(id: "s3", title: "Amazon S3", subtitle: "Multipart, transfer acceleration, S3-compatible endpoints", supportsParallelChunks: true, supportsMounting: true),
        ProviderChoice(id: "gdrive", title: "Google Drive", subtitle: "Resumable upload sessions and Drive metadata", supportsParallelChunks: false, supportsMounting: true),
        ProviderChoice(id: "dropbox", title: "Dropbox", subtitle: "Sequential upload sessions with strong resume support", supportsParallelChunks: false, supportsMounting: true),
        ProviderChoice(id: "onedrive", title: "OneDrive", subtitle: "Large file upload sessions and delta queries", supportsParallelChunks: false, supportsMounting: true),
        ProviderChoice(id: "sftp", title: "SFTP", subtitle: "Parallel channels with SSH keychain storage", supportsParallelChunks: true, supportsMounting: true),
        ProviderChoice(id: "webdav", title: "WebDAV", subtitle: "Basic, Digest, and OAuth-backed endpoints", supportsParallelChunks: false, supportsMounting: true),
    ]
}

private struct ProviderChoiceCard: View {
    let provider: ProviderChoice

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ProviderIcon(providerID: provider.id, size: 36)
            Text(provider.title)
                .font(.stratusHeadline)
            Text(provider.subtitle)
                .stratusCaption()
                .lineLimit(3)
            HStack(spacing: Spacing.xs) {
                CapabilityPill(title: provider.supportsParallelChunks ? "Parallel" : "Sequential")
                CapabilityPill(title: provider.supportsMounting ? "Finder" : "Transfer only")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

private struct CapabilityPill: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption2.weight(.medium))
            .foregroundColor(.textSecondary)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(Color.surfaceSecondary)
            .clipShape(Capsule())
    }
}
