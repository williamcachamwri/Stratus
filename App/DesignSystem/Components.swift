import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - ProviderIcon

public struct ProviderIcon: View {
    let providerID: String
    var size: CGFloat = 32

    public var body: some View {
        Group {
            if hasAssetLogo {
                assetLogo
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.08)
            } else {
                fallbackIcon
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(Text(accessibilityName))
    }

    private var assetLogo: Image {
        #if os(macOS)
        if let image = NSImage(named: assetName) {
            return Image(nsImage: image)
        }
        #endif
        return Image(assetName)
    }

    private var hasAssetLogo: Bool {
        #if os(macOS)
        return NSImage(named: assetName) != nil
        #else
        return true
        #endif
    }

    private var fallbackIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
            Image(systemName: systemImage)
                .resizable()
                .scaledToFit()
                .padding(size * 0.22)
                .foregroundColor(.secondary)
        }
    }

    private var assetName: String {
        switch providerID {
        case "s3": return "ProviderLogoAmazonAWS"
        case "wasabi": return "ProviderLogoWasabi"
        case "backblaze_b2": return "ProviderLogoBackblaze"
        case "cloudflare_r2": return "ProviderLogoCloudflare"
        case "gdrive": return "ProviderLogoGoogleDrive"
        case "dropbox": return "ProviderLogoDropbox"
        case "onedrive": return "ProviderLogoOneDrive"
        case "box": return "ProviderLogoBox"
        case "icloud": return "ProviderLogoICloud"
        default: return ""
        }
    }

    private var accessibilityName: String {
        switch providerID {
        case "s3": return "Amazon S3"
        case "wasabi": return "Wasabi"
        case "backblaze_b2": return "Backblaze B2"
        case "cloudflare_r2": return "Cloudflare R2"
        case "gdrive": return "Google Drive"
        case "dropbox": return "Dropbox"
        case "onedrive": return "OneDrive"
        case "box": return "Box"
        case "icloud": return "iCloud Drive"
        case "sftp": return "SFTP"
        case "webdav": return "WebDAV"
        case "ftp": return "FTP / FTPS"
        default: return "Cloud provider"
        }
    }

    private var systemImage: String {
        switch providerID {
        case "s3", "wasabi", "backblaze_b2", "cloudflare_r2", "minio": return "server.rack"
        case "gdrive", "dropbox", "box": return "externaldrive"
        case "onedrive", "icloud": return "icloud"
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
