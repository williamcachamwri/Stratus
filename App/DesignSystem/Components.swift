import SwiftUI

// MARK: - ProviderIcon

public struct ProviderIcon: View {
    let providerID: String
    var size: CGFloat = 32

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(backgroundColor)
                .frame(width: size, height: size)
            Image(systemName: systemImage)
                .resizable()
                .scaledToFit()
                .padding(size * 0.2)
                .foregroundColor(.white)
        }
    }

    private var backgroundColor: Color {
        switch providerID {
        case "s3", "wasabi", "backblaze_b2", "cloudflare_r2", "minio": return .s3Orange
        case "gdrive": return .googleBlue
        case "dropbox": return .dropboxBlue
        case "onedrive": return .oneDriveBlue
        case "sftp": return .sftpGray
        case "webdav": return .webdavPurple
        default: return .gray
        }
    }

    private var systemImage: String {
        switch providerID {
        case "s3", "wasabi", "backblaze_b2", "cloudflare_r2", "minio": return "server.rack"
        case "gdrive": return "doc.on.doc"
        case "dropbox": return "shippingbox"
        case "onedrive": return "icloud"
        case "sftp": return "network"
        case "webdav": return "globe"
        default: return "cloud"
        }
    }
}

// MARK: - BandwidthLabel

public struct BandwidthLabel: View {
    let bps: Double

    public var body: some View {
        Text(formatted)
            .font(.stratusSmallMono)
            .foregroundColor(.textSecondary)
    }

    private var formatted: String {
        if bps < 1024 { return String(format: "%.0f B/s", bps) }
        if bps < 1024 * 1024 { return String(format: "%.1f KB/s", bps / 1024) }
        if bps < 1024 * 1024 * 1024 { return String(format: "%.1f MB/s", bps / (1024 * 1024)) }
        return String(format: "%.1f GB/s", bps / (1024 * 1024 * 1024))
    }
}

// MARK: - ProgressRing

public struct ProgressRing: View {
    let progress: Double  // 0–1
    var size: CGFloat = 24
    var lineWidth: CGFloat = 3
    var color: Color = .accentColor

    public var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.3), value: progress)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - StatusBadge

public struct StatusBadge: View {
    public enum Status { case active, paused, failed, idle }
    let status: Status

    public var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(color.opacity(0.3), lineWidth: 3)
                    .scaleEffect(status == .active ? 1.6 : 1)
                    .opacity(status == .active ? 0 : 1)
                    .animation(
                        status == .active
                            ? .easeOut(duration: 1.0).repeatForever(autoreverses: false)
                            : .default,
                        value: status == .active
                    )
            )
    }

    private var color: Color {
        switch status {
        case .active: return .uploadActive
        case .paused: return .uploadPaused
        case .failed: return .uploadFailed
        case .idle: return .textTertiary
        }
    }
}

// MARK: - SectionHeader

public struct SectionHeader: View {
    let title: String
    var trailing: String? = nil

    public var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.textSecondary)
                .tracking(0.5)
            Spacer()
            if let t = trailing {
                Text(t)
                    .font(.caption)
                    .foregroundColor(.textTertiary)
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.sm)
    }
}

// MARK: - EmptyStateView

public struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    public var body: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: icon)
                .font(.system(size: 48, weight: .light))
                .foregroundColor(.textTertiary)
            VStack(spacing: Spacing.xs) {
                Text(title)
                    .font(.stratusHeadline)
                Text(subtitle)
                    .font(.stratusBody)
                    .foregroundColor(.textSecondary)
                    .multilineTextAlignment(.center)
            }
            if let title = actionTitle, let action {
                Button(title, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(Spacing.xxxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
