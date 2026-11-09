import SwiftUI
import AppKit
import Observation

// MARK: - Cleanup model (Trash & app uninstall)
@MainActor
@Observable
final class CleanupModel {
    var section: CleanupSection = .trash
    var items: [CleanupItem] = []
    var selected: Set<URL> = []
    var busy = false
    var status = ""
    var failures: [String] = []
    /// Set when macOS blocked access; the page explains which permission to enable.
    var accessProblem = false
    /// Files left in ~/Library by apps that were just uninstalled, offered for removal.
    var leftovers: [DiskItem] = []
    var leftoverSelection: Set<URL> = []
    var showingLeftovers = false

    let home = PermissionCenter.realHomeDirectory
    @ObservationIgnored private lazy var service = CleanupService(homeURL: home)
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var rescanTask: Task<Void, Never>?

    var folder: URL {
        section == .trash ? home.appendingPathComponent(".Trash") : URL(fileURLWithPath: "/Applications")
    }

    var selectedItems: [CleanupItem] { items.filter { selected.contains($0.id) } }
    var selectedSize: String {
        ByteCountFormatter.string(fromByteCount: selectedItems.reduce(0) { $0 + $1.bytes }, countStyle: .file)
    }

    // MARK: Loading
    /// Opens a section and scans it. The Trash is watched so items deleted in
    /// Finder appear here automatically.
    func load(_ next: CleanupSection) {
        guard !busy else { return }
        section = next
        items = []
        selected = []
        failures = []
        scan()
        watcher = next == .trash ? DirectoryWatcher(url: folder) { [weak self] in self?.scheduleRescan() } : nil
    }

    /// Debounces bursts of Trash changes (Finder moves files one at a time).
    private func scheduleRescan() {
        rescanTask?.cancel()
        rescanTask = Task {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            scan(keepSelection: true)
        }
    }

    func scan(keepSelection: Bool = false) {
        guard !busy else { return }
        busy = true
        if !keepSelection { selected = [] }
        failures = []
        accessProblem = false
        status = "Reviewing files…"
        let folder = folder, section = section
        scanTask = Task {
            defer { busy = false; scanTask = nil }
            do {
                let result = try await service.scan(folder: folder, section: section)
                items = result.items
                selected.formIntersection(Set(items.map(\.id)))
                status = section == .trash
                    ? (items.isEmpty ? "Your Trash is empty." : "\(items.count) items in Trash.")
                    : "\(items.count) apps found."
                if result.unreadableCount > 0 { status += " \(result.unreadableCount) unreadable items skipped." }
            } catch is CancellationError {
                status = "Scan cancelled."
            } catch {
                items = []
                accessProblem = CleanupService.isPermissionError(error)
                status = accessProblem
                    ? "macOS blocked access. Turn on System Monitor in System Settings › Privacy & Security › Full Disk Access."
                    : "Couldn’t read this folder: \(error.localizedDescription)"
            }
        }
    }

    func cancelScan() { scanTask?.cancel() }

    // MARK: Removal
    func removeSelected() {
        guard !busy, !selectedItems.isEmpty else { return }
        let approved = selectedItems, folder = folder
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        busy = true
        failures = []
        Task {
            defer { busy = false }
            let result = await service.remove(approved, in: folder, runningApps: running)
            items.removeAll { result.removed.contains($0.id) }
            selected.subtract(result.removed)
            failures = result.failures
            accessProblem = result.needsAccess
            status = section == .applications
                ? "\(result.removed.count) apps moved to Trash."
                : "\(result.removed.count) items permanently deleted."
            if !failures.isEmpty { status += " \(failures.count) items could not be removed." }
            if section == .applications {
                await findLeftovers(for: approved.filter { result.removed.contains($0.id) })
            }
        }
    }

    // MARK: Leftovers
    /// Looks in ~/Library for preferences, caches and other files the removed apps left behind.
    private func findLeftovers(for apps: [CleanupItem]) async {
        guard !apps.isEmpty else { return }
        let home = home
        let others = Set(items.compactMap(\.bundleIdentifier))
        let targets = apps.map { (bundleID: $0.bundleIdentifier, name: $0.url.deletingPathExtension().lastPathComponent) }
        let found = await Task.detached(priority: .userInitiated) {
            targets.flatMap { LeftoverFinder.find(bundleID: $0.bundleID, appName: $0.name, home: home, otherBundleIDs: others) }
        }.value
        guard !found.isEmpty else { return }
        leftovers = found.sorted { $0.bytes > $1.bytes }
        leftoverSelection = Set(found.map(\.url))
        showingLeftovers = true
    }

    func removeLeftovers() {
        let chosen = leftovers.filter { leftoverSelection.contains($0.url) }
        showingLeftovers = false
        guard !chosen.isEmpty else { leftovers = []; return }
        Task {
            let result = await Task.detached(priority: .userInitiated) { DiskItem.remove(chosen) { _ in true } }.value
            status += " \(result.removed.count) leftover items moved to Trash."
            failures += result.failures
            if result.needsAccess { accessProblem = true }
            leftovers = []
        }
    }

    func openAppManagementSettings() { PermissionCenter.shared.openAppManagement() }
}

// MARK: - Directory watcher
/// Calls `onChange` (on the main actor) when a folder's contents change.
@MainActor
final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject

    init?(url: URL, onChange: @escaping @MainActor () -> Void) {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                           eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { onChange() } }
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    deinit { source.cancel() }
}

// MARK: - Cleanup page
struct CleanupWorkspace: View {
    @Bindable var model: CleanupModel
    @State private var confirmingRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: model.section == .trash ? "Trash" : "Uninstall Apps",
                       symbol: model.section.symbol, subtitle: instructions)

            if model.accessProblem {
                DiskAccessBanner(startingFolder: model.section == .trash ? model.home : model.folder) {
                    model.scan(keepSelection: true)
                }
            }

            // Toolbar.
            HStack {
                Button("Refresh", systemImage: "arrow.clockwise") { model.scan(keepSelection: true) }
                    .disabled(model.busy)
                Button("Grant Folder Access…") {
                    PermissionCenter.shared.grantFolderAccess(
                        startingAt: model.section == .trash ? model.home : model.folder
                    ) { granted in
                        if granted { model.scan(keepSelection: true) }
                    }
                }
                .disabled(model.busy)
                if model.section == .trash {
                    Button("Open Trash in Finder", systemImage: "trash") { NSWorkspace.shared.open(model.folder) }
                    if model.accessProblem {
                        Button("Full Disk Access Settings") { PermissionCenter.shared.openFullDiskAccess() }
                    }
                }
                if model.section == .applications, model.accessProblem {
                    Button("Open App Management Settings") { model.openAppManagementSettings() }
                        .buttonStyle(.borderedProminent)
                }
                if model.busy {
                    ProgressView().controlSize(.small)
                    if model.status == "Reviewing files…" {
                        Button("Cancel Scan") { model.cancelScan() }
                    }
                }
            }

            // Item list.
            if model.items.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: model.section.symbol,
                                       description: Text(model.status))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.items) { item in row(item) }
                    .listStyle(.inset)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Text(model.status).font(.caption).foregroundStyle(.secondary)
            }

            if !model.failures.isEmpty {
                ScrollView {
                    Text(model.failures.joined(separator: "\n"))
                        .font(.caption).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 70)
            }

            // Selection + action bar.
            HStack {
                Button("Select All") { model.selected = Set(model.items.map(\.id)) }
                    .disabled(model.busy || model.items.isEmpty)
                Button("Deselect") { model.selected = [] }
                    .disabled(model.busy || model.selected.isEmpty)
                Spacer()
                Text("\(model.selected.count) selected · \(model.selectedSize)").font(.caption)
                Button(actionTitle) { confirmingRemoval = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selected.isEmpty || model.busy)
            }
        }
        .padding(28)
        .alert(actionTitle, isPresented: $confirmingRemoval) {
            Button("Cancel", role: .cancel) {}
            Button(model.section == .trash ? "Delete" : "Move to Trash", role: .destructive) { model.removeSelected() }
        } message: {
            Text("\(model.selected.count) items (\(model.selectedSize)). "
                 + (model.section == .applications
                    ? "Apps will move to the Trash. You’ll then be shown any files they left behind."
                    : "This can’t be undone."))
        }
        .sheet(isPresented: $model.showingLeftovers) { leftoverSheet }
    }

    // MARK: Leftover review
    private var leftoverSheet: some View {
        let selectedBytes = model.leftovers.filter { model.leftoverSelection.contains($0.url) }.reduce(0) { $0 + $1.bytes }
        return VStack(alignment: .leading, spacing: 14) {
            Label("Remove leftover files?", systemImage: "sparkles").font(.title2.bold())
            Text("The apps you removed left these files in your Library: preferences, caches, saved state and support files. They’ll move to the Trash.")
                .foregroundStyle(.secondary)
            List(model.leftovers) { item in
                let isSelected = model.leftoverSelection.contains(item.url)
                HStack {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? .purple : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                        Text(item.parent.path.replacingOccurrences(of: model.home.path, with: "~"))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(Format.fileSize(item.bytes)).font(.caption).monospacedDigit()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if isSelected { model.leftoverSelection.remove(item.url) } else { model.leftoverSelection.insert(item.url) }
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 220)
            HStack {
                Text("\(model.leftoverSelection.count) selected · \(Format.fileSize(selectedBytes))").font(.caption)
                Spacer()
                Button("Keep All") { model.leftovers = []; model.showingLeftovers = false }
                    .keyboardShortcut(.cancelAction)
                Button("Move to Trash") { model.removeLeftovers() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.leftoverSelection.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560, height: 460)
    }

    /// Clicking anywhere on a row toggles its selection.
    private func row(_ item: CleanupItem) -> some View {
        let isSelected = model.selected.contains(item.id)
        return HStack {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? .purple : .secondary)
                .font(.title3)
            FileIcon.image(for: item.url.path)
                .resizable().frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1)
                if let version = item.version {
                    Text("Version \(version)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))
                .font(.caption).monospacedDigit()
            Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !model.busy else { return }
            if isSelected { model.selected.remove(item.id) } else { model.selected.insert(item.id) }
        }
        .listRowBackground(isSelected ? Color.purple.opacity(0.12) : Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var emptyTitle: String {
        if model.busy { return "Reviewing…" }
        if model.accessProblem { return "Full Disk Access required" }
        return model.section == .trash ? "Trash is empty" : "No apps found"
    }

    private var actionTitle: String {
        model.section == .trash ? "Delete Selected…" : "Move Selected Apps to Trash…"
    }

    private var instructions: String {
        model.section == .trash
            ? "Everything in your Mac’s Trash, updated automatically. Select items to delete them permanently."
            : "Review app bundles to uninstall. Running and system apps are protected."
    }
}
