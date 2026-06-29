import SwiftUI
import StratusCore

struct UploadCenterView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var snapshot: BWSnapshot?
    @State private var uploadTasks: [UploadTaskViewModel] = []

    var body: some View {
        VStack(spacing: 0) {
            if let snap = snapshot {
                BandwidthHeader(snapshot: snap)
                    .padding(Spacing.lg)
                    .background(Color.surfacePrimary)
                Divider()
            }

            if uploadTasks.isEmpty {
                EmptyStateView(
                    icon: "arrow.up.circle",
                    title: "No Active Uploads",
                    subtitle: "Drag files here or use the Files browser to start uploading."
                )
            } else {
                List(uploadTasks, id: \.id) { task in
                    UploadItemRowView(task: task)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Upload Center")
        .onAppear { listenForBandwidth() }
    }

    private func listenForBandwidth() {
        Task { @MainActor in
            let monitor = BandwidthMonitor()
            for await snap in await monitor.updates {
                self.snapshot = snap
            }
        }
    }
}

// MARK: - BandwidthHeader

private struct BandwidthHeader: View {
    let snapshot: BWSnapshot

    var body: some View {
        HStack(spacing: Spacing.xl) {
            StatCell(label: "Current", value: BandwidthLabel(bps: snapshot.currentBPS))
            Divider().frame(height: 32)
            StatCell(label: "Average", value: BandwidthLabel(bps: snapshot.averageBPS))
            Divider().frame(height: 32)
            StatCell(label: "Peak", value: BandwidthLabel(bps: snapshot.peakBPS))
            Spacer()
            SpeedGraph(samples: [snapshot.currentBPS, snapshot.averageBPS, snapshot.peakBPS])
                .frame(width: 120, height: 40)
        }
    }
}

private struct StatCell<Content: View>: View {
    let label: String
    let value: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.textTertiary)
                .tracking(0.5)
            value
        }
    }
}

// MARK: - UploadTaskViewModel (thin presentation wrapper)

struct UploadTaskViewModel: Identifiable, Sendable {
    let id: String
    let fileName: String
    let providerID: String
    let progress: Double
    let bytesUploaded: Int64
    let totalBytes: Int64
    let state: String
    let speedBPS: Double
}

// MARK: - UploadItemRowView

struct UploadItemRowView: View {
    let task: UploadTaskViewModel

    var body: some View {
        HStack(spacing: Spacing.md) {
            ProviderIcon(providerID: task.providerID, size: 28)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(task.fileName)
                    .font(.stratusBody)
                    .lineLimit(1)
                ProgressView(value: task.progress)
                    .progressViewStyle(.linear)
                    .frame(height: 4)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: Spacing.xxs) {
                BandwidthLabel(bps: task.speedBPS)
                Text(progressText)
                    .stratusCaption()
            }
            StatusBadge(status: statusBadge)
        }
        .padding(.vertical, Spacing.xs)
    }

    private var progressText: String {
        "\(formattedBytes(task.bytesUploaded)) / \(formattedBytes(task.totalBytes))"
    }

    private var statusBadge: StatusBadge.Status {
        switch task.state {
        case "uploading": return .active
        case "paused": return .paused
        case "failed": return .failed
        default: return .idle
        }
    }

    private func formattedBytes(_ b: Int64) -> String {
        if b < 1024 { return "\(b) B" }
        if b < 1024 * 1024 { return String(format: "%.1f KB", Double(b) / 1024) }
        return String(format: "%.1f MB", Double(b) / (1024 * 1024))
    }
}
