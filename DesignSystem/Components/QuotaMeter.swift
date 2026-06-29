import SwiftUI

public struct QuotaMeter: View {
    public let usedBytes: Int64
    public let totalBytes: Int64?

    private var fraction: Double {
        guard let totalBytes, totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(usedBytes) / Double(totalBytes)))
    }

    public init(usedBytes: Int64, totalBytes: Int64?) {
        self.usedBytes = usedBytes
        self.totalBytes = totalBytes
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text("Quota")
                    .font(.stratusCaption)
                Spacer()
                Text(label)
                    .font(.stratusSmallMono)
                    .foregroundColor(.textSecondary)
            }
            ProgressView(value: fraction)
                .accessibilityLabel("Storage quota")
                .accessibilityValue(label)
        }
    }

    private var label: String {
        guard let totalBytes else { return "\(formatQuotaBytes(usedBytes)) used" }
        return "\(formatQuotaBytes(usedBytes)) / \(formatQuotaBytes(totalBytes))"
    }
}

private func formatQuotaBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}
