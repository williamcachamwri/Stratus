import SwiftUI
import StratusCore

struct ContentView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var selectedTab: AppTab = .accounts

    enum AppTab: String, CaseIterable, Identifiable {
        case accounts  = "Accounts"
        case uploads   = "Uploads"
        case sync      = "Sync"
        case browse    = "Files"
        case prefs     = "Preferences"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .accounts: return "person.crop.circle.badge.plus"
            case .uploads:  return "arrow.up.circle"
            case .sync:     return "arrow.triangle.2.circlepath"
            case .browse:   return "folder"
            case .prefs:    return "gearshape"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(AppTab.allCases, selection: $selectedTab) { tab in
                Label(tab.rawValue, systemImage: tab.icon)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 200)
        } detail: {
            switch selectedTab {
            case .accounts: AccountsView()
            case .uploads:  UploadCenterView()
            case .sync:     SyncManagerView()
            case .browse:   FileBrowserView()
            case .prefs:    PreferencesView()
            }
        }
        .navigationTitle("Stratus")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                if env.activeUploads > 0 {
                    Label("\(env.activeUploads) uploading", systemImage: "arrow.up.circle.fill")
                        .foregroundColor(.uploadActive)
                }
            }
        }
    }
}
