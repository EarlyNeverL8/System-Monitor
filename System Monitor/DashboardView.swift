import SwiftUI
import Observation

// MARK: - Navigation
enum DashboardPage: Hashable {
    case overview
    case performance
    case network
    case battery
    case cleanup(CleanupSection)
}

/// Shared so the menu bar can open the dashboard on a specific page.
@MainActor
@Observable
final class DashboardNavigation {
    static let shared = DashboardNavigation()
    var page: DashboardPage = .overview
}

// MARK: - Dashboard window
/// Sidebar + page content. Page models live here so switching pages keeps state
/// (e.g. app scan results); they're released when the window closes.
struct ContentView: View {
    @State private var navigation = DashboardNavigation.shared
    @State private var cleanup = CleanupModel()
    @State private var apps = InstalledAppsModel()
    @State private var network = NetworkModel()
    @State private var performance = PerformanceModel()
    @State private var junk = JunkModel()
    @State private var storage = StorageModel()
    @State private var managingApps = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Group {
                switch navigation.page {
                case .overview: OverviewView()
                case .performance: PerformanceView(model: performance)
                case .network: NetworkView(model: network)
                case .battery: BatteryView()
                case .cleanup(.recentFiles): RecentFilesView()
                case .cleanup(.browsers): BrowserCleanupView()
                case .cleanup(.trash): CleanupWorkspace(model: cleanup)
                case .cleanup(.junk): JunkView(model: junk)
                case .cleanup(.storage): StorageView(model: storage)
                case .cleanup(.applications): applicationsPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(.purple)
        .onChange(of: navigation.page, initial: true) { _, page in
            managingApps = false
            if page == .cleanup(.trash) { cleanup.load(.trash) }
        }
    }

    // MARK: Sidebar
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("System Monitor", systemImage: "sparkles.rectangle.stack")
                .font(.headline).padding(.bottom, 20)
            sidebarButton("Overview", symbol: "macbook", page: .overview)
            sidebarButton("Performance", symbol: "bolt.horizontal.circle", page: .performance)
            sidebarButton("Network", symbol: "network", page: .network)
            sidebarButton("Battery", symbol: "battery.100percent", page: .battery)
            Text("CLEANUP")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.65))
                .padding(.top, 18).padding(.bottom, 4)
            ForEach(CleanupSection.allCases) { section in
                sidebarButton(section.rawValue, symbol: section.symbol, page: .cleanup(section))
            }
            Spacer()
            Button { openSettings() } label: {
                Label("Settings", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8).padding(.horizontal, 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Label("Live in your menu bar", systemImage: "waveform.path")
                .font(.caption).foregroundStyle(.white.opacity(0.7))
        }
        .padding(20)
        .frame(width: 210)
        .foregroundStyle(.white)
        .background(LinearGradient(colors: [
            Color(red: 0.21, green: 0.12, blue: 0.40),
            Color(red: 0.36, green: 0.20, blue: 0.58)
        ], startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    /// The whole highlighted row is clickable, not just the text and icon.
    private func sidebarButton(_ title: String, symbol: String, page: DashboardPage) -> some View {
        let selected = navigation.page == page
        return Button {
            navigation.page = page
        } label: {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10).padding(.horizontal, 12)
                .background(.white.opacity(selected ? 0.18 : 0), in: RoundedRectangle(cornerRadius: 10))
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Applications page
    /// Installed-apps list, or the uninstall workspace after "Manage / Uninstall…".
    @ViewBuilder
    private var applicationsPage: some View {
        if managingApps {
            VStack(alignment: .leading, spacing: 0) {
                Button("Back to Applications", systemImage: "chevron.left") { managingApps = false }
                    .padding([.top, .leading], 28)
                    .disabled(cleanup.busy)
                CleanupWorkspace(model: cleanup)
            }
        } else {
            InstalledAppsView(model: apps) {
                managingApps = true
                cleanup.load(.applications)
            }
        }
    }
}
