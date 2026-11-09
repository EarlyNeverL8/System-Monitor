import SwiftUI
import AppKit
import ServiceManagement
import Observation

// MARK: - Performance model
@MainActor
@Observable
final class PerformanceModel {
    enum Tab: String, CaseIterable, Identifiable {
        case maintenance = "Maintenance"
        case loginItems = "Login Items"
        case consumers = "Heavy Consumers"
        case hungApps = "Hung Apps"
        var id: String { rawValue }
    }

    var tab: Tab = .maintenance

    // Maintenance
    var chosenTasks: Set<MaintenanceTask> = [.freeMemory, .flushDNS]
    var taskResults: [MaintenanceTask: Bool] = [:]
    var maintenanceRunning = false
    var maintenanceMessage: String?

    // Login & background items
    var launchItems: [LaunchItem] = []
    var launchBusy: Set<String> = []
    var launchMessage: String?

    // Heavy consumers & hung apps
    var processes: [ProcessUsage] = []
    var hungApps: [NSRunningApplication] = []

    @ObservationIgnored private let launchService = LaunchItemService()
    @ObservationIgnored private let sampler = ProcessSampler()

    // MARK: Maintenance
    func runMaintenance() {
        guard !maintenanceRunning, !chosenTasks.isEmpty else { return }
        maintenanceRunning = true
        maintenanceMessage = nil
        taskResults = [:]
        // Keep the user's order of the list, not set order.
        let tasks = MaintenanceTask.allCases.filter(chosenTasks.contains)
        let memoryBefore = MonitorModel.shared.info.memoryUsage
        Task {
            defer { maintenanceRunning = false }
            do {
                taskResults = try await MaintenanceRunner.run(tasks)
                let succeeded = taskResults.values.filter { $0 }.count
                maintenanceMessage = "\(succeeded) of \(tasks.count) tasks completed."
                if taskResults[.freeMemory] == true, let before = memoryBefore {
                    // Read memory again after purge to report how much was freed.
                    var sampler = SystemInfoSampler()
                    if let after = sampler.sample().memoryUsage, before > after {
                        maintenanceMessage? += " Freed \(Format.bytes(before - after)) of RAM."
                    }
                }
            } catch {
                maintenanceMessage = error.localizedDescription
            }
        }
    }

    // MARK: Login items
    func loadLaunchItems() async {
        launchItems = await launchService.scan()
    }

    func setEnabled(_ enabled: Bool, item: LaunchItem) {
        guard !launchBusy.contains(item.id) else { return }
        launchBusy.insert(item.id)
        launchMessage = nil
        Task {
            defer { launchBusy.remove(item.id) }
            do {
                try await launchService.setEnabled(enabled, item: item)
                if let index = launchItems.firstIndex(where: { $0.id == item.id }) {
                    launchItems[index].isDisabled = !enabled
                }
            } catch {
                launchMessage = "\(item.displayName): \(error.localizedDescription)"
            }
        }
    }

    // MARK: Live monitoring
    /// Samples processes (every 2 s) and hung apps (every 3 s) only while their tab is visible.
    func monitorProcesses() async {
        while !Task.isCancelled {
            processes = await sampler.sample()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func monitorHungApps() async {
        while !Task.isCancelled {
            hungApps = HungAppDetector.unresponsiveApps()
            try? await Task.sleep(for: .seconds(3))
        }
    }

    var topByCPU: [ProcessUsage] { Array(processes.sorted { $0.cpu > $1.cpu }.prefix(8)) }
    var topByMemory: [ProcessUsage] { Array(processes.sorted { $0.memory > $1.memory }.prefix(8)) }

    /// Quits an app politely; plain processes get SIGTERM. Never touches this app.
    func quit(_ process: ProcessUsage) {
        guard process.pid != ProcessInfo.processInfo.processIdentifier else { return }
        if let app = NSRunningApplication(processIdentifier: process.pid) {
            app.terminate()
        } else {
            kill(process.pid, SIGTERM)
        }
    }

    func forceQuit(_ app: NSRunningApplication) {
        app.forceTerminate()
        hungApps.removeAll { $0 == app }
    }
}

// MARK: - Performance page
struct PerformanceView: View {
    @Bindable var model: PerformanceModel
    @State private var pendingQuit: ProcessUsage?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "Performance", symbol: "bolt.horizontal.circle",
                       subtitle: "Speed up your Mac: run maintenance, manage startup items and stop apps that slow it down.")
            Picker("Section", selection: $model.tab) {
                ForEach(PerformanceModel.Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch model.tab {
            case .maintenance: maintenance
            case .loginItems: loginItems.task { await model.loadLaunchItems() }
            case .consumers: consumers.task { await model.monitorProcesses() }
            case .hungApps: hungApps.task { await model.monitorHungApps() }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert("Quit \(pendingQuit?.name ?? "")?", isPresented: Binding(isPresent: $pendingQuit)) {
            Button("Cancel", role: .cancel) {}
            Button("Quit", role: .destructive) { if let pendingQuit { model.quit(pendingQuit) } }
        } message: {
            Text("Unsaved changes in this app may be lost.")
        }
    }

    // MARK: Maintenance tab
    private var maintenance: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(MaintenanceTask.allCases) { task in
                        let chosen = model.chosenTasks.contains(task)
                        HStack(spacing: 14) {
                            Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                                .font(.title3).foregroundStyle(chosen ? .purple : .secondary)
                            Image(systemName: task.symbol).font(.title2).foregroundStyle(.purple).frame(width: 32)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(task.title).font(.headline)
                                Text(task.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let ok = model.taskResults[task] {
                                Image(systemName: ok ? "checkmark.seal.fill" : "xmark.octagon.fill")
                                    .foregroundStyle(ok ? .green : .red)
                            }
                        }
                        .card(padding: 12)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard !model.maintenanceRunning else { return }
                            if chosen { model.chosenTasks.remove(task) } else { model.chosenTasks.insert(task) }
                        }
                    }
                }
            }
            HStack {
                if let message = model.maintenanceMessage { Text(message).font(.callout).foregroundStyle(.secondary) }
                Spacer()
                if model.maintenanceRunning { ProgressView().controlSize(.small) }
                Button("Run Selected Tasks", systemImage: "play.fill") { model.runMaintenance() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.maintenanceRunning || model.chosenTasks.isEmpty)
            }
            Text("Most tasks need your administrator password, asked once per run.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Login items tab
    private var loginItems: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Background agents and daemons that start automatically. Turning one off stops it now and at future logins.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() }
            }
            if model.launchItems.isEmpty {
                ContentUnavailableView("No background items", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.launchItems) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.displayName).font(.headline)
                            Text("\(item.scope.rawValue) · \(item.label)").font(.caption).foregroundStyle(.secondary)
                            signerBadge(item)
                        }
                        Spacer()
                        if model.launchBusy.contains(item.id) { ProgressView().controlSize(.small) }
                        Toggle("Enabled", isOn: Binding(get: { !item.isDisabled },
                                                       set: { model.setEnabled($0, item: item) }))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .disabled(model.launchBusy.contains(item.id))
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            if let message = model.launchMessage { Text(message).font(.caption).foregroundStyle(.red) }
        }
    }

    /// Who signed the program: unsigned or missing programs are highlighted.
    @ViewBuilder
    private func signerBadge(_ item: LaunchItem) -> some View {
        if !item.programExists {
            Label("Program missing: safe to turn off", systemImage: "questionmark.folder")
                .font(.caption2).foregroundStyle(.orange)
        } else if let signer = item.signer {
            Label(signer.isApple ? "Signed by Apple" : "Signed by \(signer.name)", systemImage: "checkmark.seal")
                .font(.caption2).foregroundStyle(.secondary)
        } else {
            Label("Unsigned or invalid signature", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2).foregroundStyle(.orange)
        }
    }

    // MARK: Heavy consumers tab
    private var consumers: some View {
        VStack(alignment: .leading, spacing: 14) {
            coreBars
            processLists
        }
    }

    /// One bar per CPU core, from the shared live readings.
    private var coreBars: some View {
        let cores = MonitorModel.shared.info.coreUsage
        return VStack(alignment: .leading, spacing: 8) {
            Label("CPU cores · \(MonitorModel.shared.hardware.coreSummary)", systemImage: "square.grid.3x3.fill").font(.headline).foregroundStyle(.purple)
            if cores.isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 40)
            } else {
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(cores.indices, id: \.self) { index in
                        VStack(spacing: 3) {
                            GeometryReader { proxy in
                                VStack(spacing: 0) {
                                    Spacer(minLength: 0)
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.blue)
                                        .frame(height: max(2, proxy.size.height * cores[index] / 100))
                                }
                            }
                            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 3))
                            Text("\(index + 1)").font(.caption2).foregroundStyle(.secondary)
                        }
                        .accessibilityElement()
                        .accessibilityLabel("Core \(index + 1), \(Int(cores[index])) percent")
                    }
                }
                .frame(height: 70)
            }
        }
        .card()
    }

    private var processLists: some View {
        HStack(alignment: .top, spacing: 14) {
            processList(title: "Top CPU", symbol: "cpu", processes: model.topByCPU) {
                $0.cpu.formatted(.number.precision(.fractionLength(1))) + "%"
            }
            processList(title: "Top memory", symbol: "memorychip", processes: model.topByMemory) {
                Format.bytes($0.memory)
            }
        }
    }

    private func processList(title: String, symbol: String, processes: [ProcessUsage],
                             value: @escaping (ProcessUsage) -> String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.headline).foregroundStyle(.purple)
            if processes.isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            }
            ForEach(processes) { process in
                HStack(spacing: 10) {
                    if let path = process.appPath {
                        FileIcon.image(for: path).resizable().frame(width: 20, height: 20)
                    } else {
                        Image(systemName: "gearshape").frame(width: 20, height: 20).foregroundStyle(.secondary)
                    }
                    Text(process.name).lineLimit(1)
                    Spacer()
                    Text(value(process)).monospacedDigit().foregroundStyle(.secondary)
                    Button("Quit") { pendingQuit = process }.controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // MARK: Hung apps tab
    @ViewBuilder
    private var hungApps: some View {
        if !HungAppDetector.isAvailable {
            ContentUnavailableView("Not available", systemImage: "exclamationmark.triangle",
                                   description: Text("This version of macOS doesn’t expose app responsiveness."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.hungApps.isEmpty {
            ContentUnavailableView("All apps are responding", systemImage: "checkmark.circle.fill",
                                   description: Text("Checked every few seconds. Apps that stop responding appear here."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 10) {
                ForEach(model.hungApps, id: \.processIdentifier) { app in
                    HStack(spacing: 12) {
                        if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 32, height: 32) }
                        VStack(alignment: .leading) {
                            Text(app.localizedName ?? "Unknown app").font(.headline)
                            Text("Not responding").font(.caption).foregroundStyle(.red)
                        }
                        Spacer()
                        Button("Force Quit", role: .destructive) { model.forceQuit(app) }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                    }
                    .card(padding: 12)
                }
                Spacer()
            }
        }
    }
}
