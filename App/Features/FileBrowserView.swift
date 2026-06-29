import SwiftUI
import StratusCore
import QuickLook

struct FileBrowserView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var selectedAccount: CloudAccount?
    @State private var currentPath: CloudPath = CloudPath("/")
    @State private var items: [CloudFileItem] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var selectedItem: CloudFileItem?
    @State private var pathHistory: [CloudPath] = []

    var body: some View {
        HSplitView {
            // Account sidebar
            List(env.accounts, id: \.id, selection: $selectedAccount) { account in
                HStack(spacing: Spacing.sm) {
                    ProviderIcon(providerID: account.providerID, size: 20)
                    Text(account.displayName)
                        .font(.stratusBody)
                }
                .tag(account)
            }
            .listStyle(.sidebar)
            .frame(minWidth: 150, idealWidth: 180)

            // File list
            VStack(spacing: 0) {
                PathBar(path: currentPath, history: pathHistory) { path in
                    navigate(to: path)
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .background(Color.surfacePrimary)
                Divider()

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = error {
                    EmptyStateView(icon: "exclamationmark.triangle", title: "Load Failed", subtitle: err)
                } else if items.isEmpty {
                    EmptyStateView(icon: "folder", title: "Empty Folder", subtitle: "This directory has no files.")
                } else {
                    List(items, id: \.id, selection: $selectedItem) { item in
                        FileItemRow(item: item)
                            .tag(item)
                            .onTapGesture(count: 2) {
                                if item.isDirectory { navigate(to: item.path) }
                            }
                    }
                    .listStyle(.inset)
                }
            }
        }
        .navigationTitle("Files")
        .onChange(of: selectedAccount) { _, _ in
            currentPath = CloudPath("/")
            loadItems()
        }
    }

    private func navigate(to path: CloudPath) {
        pathHistory.append(currentPath)
        currentPath = path
        loadItems()
    }

    private func loadItems() {
        guard let account = selectedAccount,
              let provider = env.providerRegistry.provider(id: account.id) else { return }
        isLoading = true
        error = nil
        Task {
            do {
                let result = try await provider.listDirectory(path: currentPath, account: account, pageToken: nil)
                await MainActor.run {
                    items = result.items.sorted { ($0.isDirectory ? 0 : 1) < ($1.isDirectory ? 0 : 1) }
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}

// MARK: - PathBar

private struct PathBar: View {
    let path: CloudPath
    let history: [CloudPath]
    let onNavigate: (CloudPath) -> Void

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Button {
                if let prev = history.last { onNavigate(prev) }
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(history.isEmpty)
            .buttonStyle(.borderless)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(pathComponents, id: \.path) { component in
                        HStack(spacing: Spacing.xxs) {
                            if component.path != "/" {
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.textTertiary)
                            }
                            Button(component.lastComponent) {
                                onNavigate(component)
                            }
                            .buttonStyle(.borderless)
                            .foregroundColor(component.path == path.path ? .textPrimary : .textSecondary)
                        }
                    }
                }
            }
        }
    }

    private var pathComponents: [CloudPath] {
        var parts: [CloudPath] = [CloudPath("/")]
        var accumulated = ""
        for component in path.path.split(separator: "/") {
            accumulated += "/\(component)"
            parts.append(CloudPath(accumulated))
        }
        return parts
    }
}

// MARK: - FileItemRow

private struct FileItemRow: View {
    let item: CloudFileItem

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: item.isDirectory ? "folder.fill" : fileIcon)
                .foregroundColor(item.isDirectory ? .yellow : .textSecondary)
                .frame(width: 20)
            Text(item.name)
                .font(.stratusBody)
                .lineLimit(1)
            Spacer()
            if let size = item.size, !item.isDirectory {
                Text(formatSize(size))
                    .stratusCaption()
            }
            if let date = item.modificationDate {
                Text(date, style: .relative)
                    .stratusCaption()
                    .frame(width: 80, alignment: .trailing)
            }
        }
        .padding(.vertical, Spacing.xxs)
    }

    private var fileIcon: String {
        let ext = (item.name as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.richtext"
        case "jpg", "jpeg", "png", "gif", "heic", "webp": return "photo"
        case "mp4", "mov", "avi", "mkv": return "video"
        case "mp3", "aac", "wav", "flac": return "music.note"
        case "zip", "tar", "gz", "bz2", "7z": return "archivebox"
        case "swift", "py", "js", "ts", "go", "rs": return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }

    private func formatSize(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / (1024 * 1024)) }
        return String(format: "%.2f GB", Double(bytes) / (1024 * 1024 * 1024))
    }
}
