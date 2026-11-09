import SwiftUI
import ServiceManagement
import Observation

// MARK: - Settings
/// User preferences, stored in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    /// What the menu bar item shows next to its icon.
    enum MenuBarStyle: String, CaseIterable, Identifiable {
        case icon, cpu, cpuMemory, network, all
        var id: String { rawValue }

        var title: String {
            switch self {
            case .icon: "Icon only"
            case .cpu: "CPU"
            case .cpuMemory: "CPU and memory"
            case .network: "Network speed"
            case .all: "CPU, memory and network"
            }
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    var menuBarStyle: MenuBarStyle { didSet { defaults.set(menuBarStyle.rawValue, forKey: Key.menuBarStyle) } }
    var alertsEnabled: Bool { didSet { defaults.set(alertsEnabled, forKey: Key.alertsEnabled) } }
    var highCPUAlert: Bool { didSet { defaults.set(highCPUAlert, forKey: Key.highCPUAlert) } }
    var highCPUThreshold: Double { didSet { defaults.set(highCPUThreshold, forKey: Key.highCPUThreshold) } }
    var lowDiskAlert: Bool { didSet { defaults.set(lowDiskAlert, forKey: Key.lowDiskAlert) } }
    var lowDiskGigabytes: Double { didSet { defaults.set(lowDiskGigabytes, forKey: Key.lowDiskGigabytes) } }
    var memoryPressureAlert: Bool { didSet { defaults.set(memoryPressureAlert, forKey: Key.memoryPressureAlert) } }
    var batteryHealthAlert: Bool { didSet { defaults.set(batteryHealthAlert, forKey: Key.batteryHealthAlert) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.menuBarStyle: MenuBarStyle.cpu.rawValue,
            Key.highCPUAlert: true, Key.highCPUThreshold: 90.0,
            Key.lowDiskAlert: true, Key.lowDiskGigabytes: 10.0,
            Key.memoryPressureAlert: true, Key.batteryHealthAlert: true
        ])
        menuBarStyle = MenuBarStyle(rawValue: defaults.string(forKey: Key.menuBarStyle) ?? "") ?? .cpu
        alertsEnabled = defaults.bool(forKey: Key.alertsEnabled)
        highCPUAlert = defaults.bool(forKey: Key.highCPUAlert)
        highCPUThreshold = defaults.double(forKey: Key.highCPUThreshold)
        lowDiskAlert = defaults.bool(forKey: Key.lowDiskAlert)
        lowDiskGigabytes = defaults.double(forKey: Key.lowDiskGigabytes)
        memoryPressureAlert = defaults.bool(forKey: Key.memoryPressureAlert)
        batteryHealthAlert = defaults.bool(forKey: Key.batteryHealthAlert)
    }

    private enum Key {
        static let menuBarStyle = "menuBarStyle"
        static let alertsEnabled = "alertsEnabled"
        static let highCPUAlert = "alertHighCPU"
        static let highCPUThreshold = "alertHighCPUThreshold"
        static let lowDiskAlert = "alertLowDisk"
        static let lowDiskGigabytes = "alertLowDiskGigabytes"
        static let memoryPressureAlert = "alertMemoryPressure"
        static let batteryHealthAlert = "alertBatteryHealth"
    }
}

// MARK: - Settings window
struct SettingsView: View {
    @Bindable private var settings = AppSettings.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?
    @State private var confirmingHistoryReset = false

    var body: some View {
        Form {
            Section("General") {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginItemError {
                    Text(loginItemError).font(.caption).foregroundStyle(.red)
                }
                Picker("Menu bar shows", selection: $settings.menuBarStyle) {
                    ForEach(AppSettings.MenuBarStyle.allCases) { Text($0.title).tag($0) }
                }
            }

            Section {
                Toggle("Send notifications", isOn: $settings.alertsEnabled)
                    .onChange(of: settings.alertsEnabled) { _, enabled in
                        if enabled { Task { await AlertCenter.shared.requestAuthorization() } }
                    }
                Group {
                    HStack {
                        Toggle("CPU stays above", isOn: $settings.highCPUAlert)
                        Spacer()
                        Stepper("\(Int(settings.highCPUThreshold)) % for 2 minutes",
                                value: $settings.highCPUThreshold, in: 50...100, step: 5)
                    }
                    HStack {
                        Toggle("Free disk space below", isOn: $settings.lowDiskAlert)
                        Spacer()
                        Stepper("\(Int(settings.lowDiskGigabytes)) GB",
                                value: $settings.lowDiskGigabytes, in: 1...200, step: 1)
                    }
                    Toggle("Memory pressure becomes critical", isOn: $settings.memoryPressureAlert)
                    Toggle("Battery health drops below 80 %", isOn: $settings.batteryHealthAlert)
                }
                .disabled(!settings.alertsEnabled)
            } header: {
                Text("Alerts")
            } footer: {
                Text("Each alert is sent at most once an hour.").font(.caption).foregroundStyle(.secondary)
            }

            Section("Data & Permissions") {
                LabeledContent("Disk & Folder Access") {
                    HStack(spacing: 8) {
                        Button("Grant Folder Access…") {
                            PermissionCenter.shared.grantFolderAccess(startingAt: PermissionCenter.realHomeDirectory) { _ in }
                        }
                        Button("Full Disk Access…") {
                            PermissionCenter.shared.openFullDiskAccess()
                        }
                    }
                }
                LabeledContent("Permissions") {
                    HStack(spacing: 8) {
                        Button("App Management…") {
                            PermissionCenter.shared.openAppManagement()
                        }
                        Button("Set Up Permissions…") {
                            WindowCoordinator.shared.showOnboarding(startAt: .loginItem)
                        }
                    }
                }
                LabeledContent("Chart history") {
                    Button("Clear History…") { confirmingHistoryReset = true }
                }
                LabeledContent("Dashboard") {
                    Button("Open Dashboard") { WindowCoordinator.shared.showDashboard() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .alert("Clear chart history?", isPresented: $confirmingHistoryReset) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) { MonitorModel.shared.clearHistory() }
        } message: {
            Text("The 1-hour, 24-hour and 7-day charts start again from now. Battery health history is kept.")
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        loginItemError = nil
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginItemError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
