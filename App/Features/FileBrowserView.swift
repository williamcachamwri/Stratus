import AppKit
import SwiftUI
import StratusCore
import UniformTypeIdentifiers

struct FileBrowserView: View {
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var env: AppEnvironment
    @State private var selectedAccount: CloudAccount?
    @State private var currentPath: CloudPath = CloudPath("/")
    @State private var items: [CloudFileItem] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var selectedItem: CloudFileItem?
    @State private var pathHistory: [CloudPath] = []
    @State private var isDraggingOver = false
    @State private var uploadFeedback: String?

    var body: some View {
        HSplitView {
            // Account sidebar
            List(env.accounts, id: \.id, selection: $selectedAccount) { account in
                HStack(spacing: Spacing.sm) {
                    ProviderIcon(providerID: account.providerID, size: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.email ?? account.displayName)
                            .font(.stratusBody)
                            .lineLimit(1)
                        if account.email != nil {
                            Text(account.displayName)
                                .font(.caption)
                                .foregroundColor(.textSecondary)
                                .lineLimit(1)
                        }
                    }
                }
                .tag(account)
            }
            .listStyle(.sidebar)
            .frame(minWidth: 150, idealWidth: 180)

            // File list
            ZStack {
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
                        EmptyStateView(
                            icon: "folder",
                            title: "Empty Folder",
                            subtitle: selectedAccount == nil
                                ? "Select an account to browse files."
                                : "Drop files here to upload them."
                        )
                    } else {
                        List(items, id: \.id, selection: $selectedItem) { item in
                            FileItemRow(item: item)
                                .tag(item)
                                .onTapGesture(count: 2) {
                                    activate(item)
                                }
                                .contextMenu {
                                    googleDriveQuickActions(for: item)
                                }
                        }
                        .listStyle(.inset)
                    }

                    if let feedback = uploadFeedback {
                        HStack {
                            Image(systemName: "arrow.up.circle")
                            Text(feedback)
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.vertical, Spacing.xs)
                        .transition(.opacity)
                    }
                }

                // Drop-target overlay
                if isDraggingOver {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor, lineWidth: 2)
                        .background(Color.accentColor.opacity(0.08).cornerRadius(8))
                        .overlay {
                            Label("Drop to upload", systemImage: "arrow.up.to.line")
                                .font(.title3.weight(.medium))
                                .foregroundColor(.accentColor)
                        }
                        .padding(Spacing.md)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isDraggingOver, perform: handleDrop)
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

    private func activate(_ item: CloudFileItem) {
        if item.isDirectory {
            navigate(to: item.path)
            return
        }

        guard selectedAccount?.providerID == "gdrive",
              let url = GoogleDriveWebLink.url(fileID: item.id, mimeType: item.contentType) else { return }
        openURL(url)
    }

    @ViewBuilder
    private func googleDriveQuickActions(for item: CloudFileItem) -> some View {
        if selectedAccount?.providerID == "gdrive",
           let url = GoogleDriveWebLink.url(fileID: item.id, mimeType: item.contentType) {
            Button(GoogleDriveWebLink.actionTitle(mimeType: item.contentType), systemImage: "safari") {
                openURL(url)
            }

            Button("Copy Google Drive Link", systemImage: "link") {
                copyGoogleDriveLink(url)
            }
        }
    }

    private func copyGoogleDriveLink(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        uploadFeedback = "Copied Google Drive link"
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if uploadFeedback == "Copied Google Drive link" {
                uploadFeedback = nil
            }
        }
    }

    private func loadItems() {
        guard let account = selectedAccount else { return }
        let path = currentPath
        items = []
        isLoading = true
        error = nil
        Task {
            guard let provider = await env.providerRegistry.provider(id: account.providerID) else {
                await MainActor.run {
                    self.error = "No provider is registered for \(account.displayName). Check account configuration."
                    isLoading = false
                }
                return
            }

            do {
                let result = try await provider.listDirectory(path: path, account: account, pageToken: nil)
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

    @discardableResult
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let account = selectedAccount else { return false }
        let destination = currentPath
        let accountID = account.id

        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard
                    let data = item as? Data,
                    let url = URL(dataRepresentation: data, relativeTo: nil)
                else { return }

                Task { @MainActor in
                    do {
                        _ = try await env.uploadEngine.upload(
                            fileURL: url,
                            destination: destination,
                            accountID: accountID
                        )
                        let name = url.lastPathComponent
                        uploadFeedback = "Queued \(name) for upload"
                        try? await Task.sleep(for: .seconds(3))
                        uploadFeedback = nil
                    } catch {
                        uploadFeedback = "Upload failed: \(error.localizedDescription)"
                        try? await Task.sleep(for: .seconds(4))
                        uploadFeedback = nil
                    }
                }
            }
        }
        return true
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
