import SwiftUI
import AppKit
import Charts
import Observation

// MARK: - System junk model
@MainActor
@Observable
final class JunkModel {
    var groups: [JunkGroup] = []
    var selected: Set<URL> = []
    var expanded: Set<JunkCategory> = []
    var busy = false
    var scanned = false
    var status = "Scan to find caches, logs and other files you can safely remove."
    var failures: [String] = []
    @ObservationIgnored private let service = JunkService()
    @ObservationIgnored private var task: Task<Void, Never>?

    var selectedItems: [DiskItem] { groups.flatMap(\.items).filter { selected.contains($0.url) } }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.bytes } }
    var totalBytes: Int64 { groups.reduce(0) { $0 + $1.bytes } }

    func scan() {
        guard !busy else { return }
        busy = true
        failures = []
        status = "Looking for junk…"
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        task = Task {
            defer { busy = false; task = nil }
            do {
                groups = try await service.scan(runningBundleIDs: running)
                selected = Set(groups.filter(\.category.selectedByDefault).flatMap(\.items).map(\.url))
                scanned = true
                status = groups.isEmpty ? "No junk found." : "\(Format.fileSize(totalBytes)) of junk found."
            } catch {
                status = "Scan cancelled."
            }
        }
    }

    func cancel() { task?.cancel() }

    func clean() {
        let items = selectedItems
        guard !busy, !items.isEmpty else { return }
        busy = true
        var categories: [URL: JunkCategory] = [:]
        for group in groups { for item in group.items { categories[item.url] = group.category } }
        Task {
            defer { busy = false }
            let result = await service.remove(items, categories: categories)
            for index in groups.indices { groups[index].items.removeAll { result.removed.contains($0.url) } }
            groups.removeAll { $0.items.isEmpty }
            selected.subtract(result.removed)
            failures = result.failures
            let freed = items.filter { result.removed.contains($0.url) }.reduce(0) { $0 + $1.bytes }
            status = "Freed \(Format.fileSize(freed))."
            if !failures.isEmpty { status += " \(failures.count) items couldn’t be removed (in use or protected)." }
        }
    }

    /// Selects or deselects every item in a category.
    func toggle(_ group: JunkGroup) {
        let urls = Set(group.items.map(\.url))
        if urls.isSubset(of: selected) { selected.subtract(urls) } else { selected.formUnion(urls) }
    }
}

// MARK: - System junk page
struct JunkView: View {
    @Bindable var model: JunkModel
    @State private var confirming = false
    private var permissions = PermissionCenter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "System Junk", symbol: "sparkles",
                       subtitle: "Caches, logs and build files that apps recreate when needed. Nothing personal is touched.")
            if !permissions.diskAccessReady {
                DiskAccessBanner { model.scan() }
            }
            HStack {
                Button(model.scanned ? "Scan Again" : "Scan", systemImage: "magnifyingglass") { model.scan() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy)
                Button("Grant Folder Access…") {
                    permissions.grantFolderAccess(startingAt: PermissionCenter.realHomeDirectory) { granted in
                        if granted { model.scan() }
                    }
                }
                .disabled(model.busy)
                if model.busy {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { model.cancel() }
                }
                Spacer()
                Text(model.status).font(.callout).foregroundStyle(.secondary)
            }

            if model.groups.isEmpty {
                ContentUnavailableView(model.scanned ? "Nothing to clean" : "Find system junk",
                                       systemImage: "sparkles", description: Text(model.status))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.groups) { group in
                        DisclosureGroup(isExpanded: Binding(
                            get: { model.expanded.contains(group.category) },
                            set: { if $0 { model.expanded.insert(group.category) } else { model.expanded.remove(group.category) } }
                        )) {
                            ForEach(group.items) { item in itemRow(item) }
                        } label: {
                            groupRow(group)
                        }
                    }
                }
                .listStyle(.inset)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            if !model.failures.isEmpty {
                ScrollView {
                    Text(model.failures.joined(separator: "\n")).font(.caption).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 60)
            }

            HStack {
                Spacer()
                Text("\(Format.fileSize(model.selectedBytes)) selected").font(.callout)
                Button("Clean…") { confirming = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy || model.selected.isEmpty)
            }
        }
        .padding(28)
        .alert("Clean \(Format.fileSize(model.selectedBytes))?", isPresented: $confirming) {
            Button("Cancel", role: .cancel) {}
            Button("Clean", role: .destructive) { model.clean() }
        } message: {
            Text("Caches and logs are deleted permanently. Device backups are moved to the Trash. Apps may start a little slower the first time as they rebuild their caches.")
        }
    }

    private func groupRow(_ group: JunkGroup) -> some View {
        let urls = Set(group.items.map(\.url))
        let selectedCount = urls.intersection(model.selected).count
        let symbol = selectedCount == 0 ? "circle" : selectedCount == urls.count ? "checkmark.circle.fill" : "minus.circle.fill"
        return HStack(spacing: 12) {
            Button { model.toggle(group) } label: {
                Image(systemName: symbol).font(.title3).foregroundStyle(selectedCount == 0 ? Color.secondary : Color.purple)
            }
            .buttonStyle(.plain)
            .disabled(model.busy)
            .accessibilityLabel("Select \(group.category.rawValue)")
            Image(systemName: group.category.symbol).font(.title3).foregroundStyle(.purple).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.category.rawValue).font(.headline)
                Text(group.category.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(Format.fileSize(group.bytes)).monospacedDigit()
        }
        .padding(.vertical, 4)
    }

    private func itemRow(_ item: DiskItem) -> some View {
        let isSelected = model.selected.contains(item.url)
        return HStack {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? .purple : .secondary)
            Text(item.name).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(Format.fileSize(item.bytes)).font(.caption).monospacedDigit()
            Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !model.busy else { return }
            if isSelected { model.selected.remove(item.url) } else { model.selected.insert(item.url) }
        }
    }
}

// MARK: - Storage model
@MainActor
@Observable
final class StorageModel {
    enum Threshold: Int64, CaseIterable, Identifiable {
        case mb50 = 50_000_000, mb100 = 100_000_000, mb500 = 500_000_000, gb1 = 1_000_000_000
        var id: Int64 { rawValue }
        var title: String { Format.fileSize(rawValue) }
    }

    var scan = StorageScan()
    var threshold: Threshold = .mb100
    var selected: Set<URL> = []
    var busy = false
    var scanned = false
    var progress = ""
    var status = "Scan to see what’s using space in your home folder."
    var failures: [String] = []
    @ObservationIgnored private let scanner = StorageScanner()
    @ObservationIgnored private var task: Task<Void, Never>?

    var selectedFiles: [DiskItem] { scan.largeFiles.map(\.item).filter { selected.contains($0.url) } }

    func start() {
        guard !busy else { return }
        busy = true
        failures = []
        selected = []
        status = "Measuring folders…"
        let threshold = threshold.rawValue
        task = Task {
            defer { busy = false; task = nil; progress = "" }
            do {
                scan = try await scanner.scan(threshold: threshold) { folder in
                    Task { @MainActor in self.progress = folder }
                }
                scanned = true
                let home = scan.folders.reduce(0) { $0 + $1.bytes }
                status = "Home folder uses \(Format.fileSize(home)). \(scan.largeFiles.count) large items found."
                if scan.unreadable > 0 { status += " \(scan.unreadable) locations couldn’t be read (Full Disk Access may be off)." }
            } catch is CancellationError {
                status = "Scan cancelled."
            } catch {
                status = CleanupService.isPermissionError(error)
                    ? "Grant access to your Home folder or enable Full Disk Access to scan your storage."
                    : "Scan failed: \(error.localizedDescription)"
            }
        }
    }

    func cancel() { task?.cancel() }

    func trashSelected() {
        let items = selectedFiles
        guard !busy, !items.isEmpty else { return }
        busy = true
        Task {
            defer { busy = false }
            let result = await scanner.trash(items)
            scan.largeFiles.removeAll { result.removed.contains($0.id) }
            selected.subtract(result.removed)
            failures = result.failures
            status = "\(result.removed.count) items moved to the Trash. Empty the Trash to free the space."
        }
    }
}

// MARK: - Storage page
struct StorageView: View {
    @Bindable var model: StorageModel
    @State private var confirming = false
    private var monitor = MonitorModel.shared
    private var permissions = PermissionCenter.shared

    init(model: StorageModel) { self.model = model }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Storage", symbol: "chart.pie",
                       subtitle: "See which folders take up space and find large files you no longer need.")
            if !permissions.diskAccessReady || model.scan.unreadable > 0 {
                DiskAccessBanner { model.start() }
            }
            HStack {
                Button(model.scanned ? "Scan Again" : "Scan Home Folder", systemImage: "magnifyingglass") { model.start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy)
                Button("Grant Folder Access…") {
                    permissions.grantFolderAccess(startingAt: PermissionCenter.realHomeDirectory) { granted in
                        if granted { model.start() }
                    }
                }
                .disabled(model.busy)
                Picker("Large files from", selection: $model.threshold) {
                    ForEach(StorageModel.Threshold.allCases) { Text($0.title).tag($0) }
                }
                .fixedSize()
                .disabled(model.busy)
                if model.busy {
                    ProgressView().controlSize(.small)
                    Text(model.progress).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Button("Cancel") { model.cancel() }
                }
                Spacer()
            }
            Text(model.status).font(.callout).foregroundStyle(.secondary)

            if model.scanned {
                HStack(alignment: .top, spacing: 14) {
                    folderChart.frame(maxWidth: 360)
                    largeFiles
                }
            } else {
                ContentUnavailableView("See what’s using your disk", systemImage: "chart.pie",
                                       description: Text(Format.storageSummary(available: monitor.info.diskSpaceAvailable,
                                                                               total: monitor.info.diskSpaceTotal)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(28)
        .alert("Move \(model.selected.count) items to the Trash?", isPresented: $confirming) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) { model.trashSelected() }
        } message: {
            Text("You can restore them from the Trash until it’s emptied.")
        }
    }

    /// Top folders in the home folder, largest first.
    private var folderChart: some View {
        let folders = Array(model.scan.folders.filter { $0.bytes > 0 }.prefix(10))
        return VStack(alignment: .leading, spacing: 10) {
            Label("Home folder", systemImage: "house").font(.headline).foregroundStyle(.purple)
            Chart(folders) { folder in
                BarMark(x: .value("Size", Double(folder.bytes) / 1e9), y: .value("Folder", folder.name))
                    .foregroundStyle(Color.purple.gradient)
                    .annotation(position: .trailing) {
                        Text(Format.fileSize(folder.bytes)).font(.caption2).foregroundStyle(.secondary)
                    }
            }
            .chartXAxis(.hidden)
            .chartYAxis { AxisMarks { AxisValueLabel() } }
            .frame(maxHeight: .infinity)
            Text(Format.storageSummary(available: monitor.info.diskSpaceAvailable, total: monitor.info.diskSpaceTotal))
                .font(.caption).foregroundStyle(.secondary)
        }
        .card()
    }

    private var largeFiles: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Large files", systemImage: "doc.badge.ellipsis").font(.headline).foregroundStyle(.purple)
            if model.scan.largeFiles.isEmpty {
                Text("No files larger than \(model.threshold.title) outside ~/Library.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.scan.largeFiles) { file in fileRow(file) }
                    .listStyle(.inset)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            if !model.failures.isEmpty {
                Text(model.failures.joined(separator: "\n")).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
            HStack {
                Text("\(model.selected.count) selected · \(Format.fileSize(model.selectedFiles.reduce(0) { $0 + $1.bytes }))")
                    .font(.caption)
                Spacer()
                Button("Move to Trash…") { confirming = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy || model.selected.isEmpty)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }

    private func fileRow(_ file: LargeFile) -> some View {
        let isSelected = model.selected.contains(file.id)
        return HStack(spacing: 10) {
            if file.isPackage {
                Image(systemName: "lock.circle").foregroundStyle(.secondary)
                    .help("Bundles like photo libraries can only be revealed in Finder.")
            } else {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .purple : .secondary)
            }
            FileIcon.image(for: file.item.url.path).resizable().frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.item.name).lineLimit(1).truncationMode(.middle)
                Text(file.item.parent.path.replacingOccurrences(of: PermissionCenter.realHomeDirectory.path, with: "~"))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if let modified = file.modified {
                Text(modified.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
            }
            Text(Format.fileSize(file.item.bytes)).font(.caption).monospacedDigit().frame(width: 70, alignment: .trailing)
            Button { NSWorkspace.shared.activateFileViewerSelecting([file.item.url]) } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !model.busy, !file.isPackage else { return }
            if isSelected { model.selected.remove(file.id) } else { model.selected.insert(file.id) }
        }
    }
}
