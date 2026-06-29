import SwiftUI
import StratusCore

public struct ProviderPickerView: View {
    @ObservedObject private var catalog = ProviderDefinitionCatalog.shared
    public let providers: [ProviderChoice]?
    public var onSelect: (ProviderChoice) -> Void

    private var visibleProviders: [ProviderChoice] {
        providers ?? catalog.providerChoices()
    }

    public let showsHeader: Bool

    public init(
        providers: [ProviderChoice]? = nil,
        showsHeader: Bool = true,
        onSelect: @escaping (ProviderChoice) -> Void = { _ in }
    ) {
        self.providers = providers
        self.showsHeader = showsHeader
        self.onSelect = onSelect
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                if showsHeader {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Connect a Cloud Account")
                            .font(.stratusTitle)
                        Text("Providers are loaded from ProviderDefinitions.json so the onboarding UI matches the real backend capabilities.")
                            .stratusCaption()
                    }
                }

                if visibleProviders.isEmpty {
                    EmptyStateView(
                        icon: "externaldrive.badge.questionmark",
                        title: "No Provider Definitions",
                        subtitle: "ProviderDefinitions.json was not found in the app bundle or repository Resources folder."
                    )
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: Spacing.md)], spacing: Spacing.md) {
                        ForEach(visibleProviders) { provider in
                            Button {
                                onSelect(provider)
                            } label: {
                                ProviderChoiceCard(provider: provider)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(Spacing.xl)
        }
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
