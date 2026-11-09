import AppIntents

// MARK: - Shortcuts & Spotlight actions
/// Dashboard pages that Shortcuts can open.
enum DashboardPageOption: String, AppEnum {
    case overview, performance, network, battery, junk, storage, trash, applications

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Dashboard Page"
    static let caseDisplayRepresentations: [DashboardPageOption: DisplayRepresentation] = [
        .overview: "Overview",
        .performance: "Performance",
        .network: "Network",
        .battery: "Battery",
        .junk: "System Junk",
        .storage: "Storage",
        .trash: "Trash",
        .applications: "Applications"
    ]

    var page: DashboardPage {
        switch self {
        case .overview: .overview
        case .performance: .performance
        case .network: .network
        case .battery: .battery
        case .junk: .cleanup(.junk)
        case .storage: .cleanup(.storage)
        case .trash: .cleanup(.trash)
        case .applications: .cleanup(.applications)
        }
    }
}

struct OpenDashboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Open System Monitor"
    static let description = IntentDescription("Opens the System Monitor dashboard on the page you choose.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Page", default: .overview)
    var page: DashboardPageOption

    @MainActor
    func perform() async throws -> some IntentResult {
        WindowCoordinator.shared.show(page: page.page)
        return .result()
    }
}

struct SystemStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Mac Status"
    static let description = IntentDescription("Returns current CPU, memory, storage and network readings.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let monitor = MonitorModel.shared
        // Right after launch the first reading may not have arrived yet.
        for _ in 0..<30 where monitor.info.cpuUsage == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        let info = monitor.info
        let summary = [
            "CPU \(Format.percent(info.cpuUsage))",
            "memory \(Format.bytes(info.memoryUsage)) of \(Format.bytes(info.memoryTotal))",
            Format.storageSummary(available: info.diskSpaceAvailable, total: info.diskSpaceTotal),
            "network ↓ \(Format.rate(info.downloadRate)) ↑ \(Format.rate(info.uploadRate))"
        ].joined(separator: ", ")
        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
    }
}

struct SystemMonitorShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SystemStatusIntent(),
                    phrases: ["Get my Mac’s status in \(.applicationName)", "How is my Mac doing in \(.applicationName)"],
                    shortTitle: "Mac Status", systemImageName: "gauge.with.dots.needle.50percent")
        AppShortcut(intent: OpenDashboardIntent(),
                    phrases: ["Open \(.applicationName)", "Open \(\.$page) in \(.applicationName)"],
                    shortTitle: "Open Dashboard", systemImageName: "macbook")
    }
}
