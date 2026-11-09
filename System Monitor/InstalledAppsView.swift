import SwiftUI
import AppKit
import Observation

// MARK: - Installed apps model
@MainActor
@Observable
final class InstalledAppsModel {
    var apps: [InstalledApp] = []
    var updates: [URL: AppUpdateState] = [:]
    var search = ""
    var selected: Set<URL> = []
    var status = "Scan to find installed apps."
    var busy = false
    var country = Locale.current.region?.identifier ?? "US"
    var scanWarnings: [String] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let scanner = InstalledAppScanner()
    @ObservationIgnored private let lookup = UpdateLookup()
    @ObservationIgnored private let updater = AppUpdater()
    @ObservationIgnored private var extraFolders: [URL] = []

    var visibleApps: [InstalledApp] {
        apps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }

    /// Apps with an update System Monitor can install itself.
    var updatableApps: [InstalledApp] { apps.filter { updates[$0.id]?.isAutomaticUpdate == true } }

    /// "Update All" targets the selected updatable apps, or every updatable app if none are selected.
    var updateTargets: [InstalledApp] {
        let chosen = updatableApps.filter { selected.contains($0.id) }
        return chosen.isEmpty ? updatableApps : chosen
    }

    var roots: [URL] {
        FileManager.default.urls(for: .applicationDirectory, in: .allDomainsMask)
            + [URL(fileURLWithPath: "/Applications"),
               PermissionCenter.realHomeDirectory.appendingPathComponent("Applications")]
            + PermissionCenter.shared.authorizedFolders
            + extraFolders
    }

    // MARK: Scanning
    func scan() {
        guard !busy else { return }
        busy = true
        status = "Scanning application folders…"
        updates = [:]
        scanWarnings = []
        let roots = roots
        task = Task {
            defer { busy = false; task = nil }
            do {
                let result = try await scanner.scan(roots: roots)
                apps = result.apps
                selected.formIntersection(Set(apps.map(\.id)))
                scanWarnings = result.inaccessibleFolders
                status = "\(apps.count) apps found."
                if !scanWarnings.isEmpty { status += " Some locations could not be read." }
            } catch is CancellationError {
                status = "Scan cancelled."
            } catch {
                status = "Scan failed: \(error.localizedDescription)"
            }
        }
    }

    /// Adds a folder of apps stored outside the standard Applications folders.
    func includeFolder() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Include in Scan"
        panel.message = "Choose additional folders that contain apps (such as /Applications or your Home folder)."
        panel.begin { [weak self] response in
            guard response == .OK, let self else { return }
            for url in panel.urls {
                PermissionCenter.shared.saveBookmark(for: url)
                if !self.extraFolders.contains(url) {
                    self.extraFolders.append(url)
                }
            }
            scan()
        }
    }

    // MARK: Checking for updates
    func checkUpdates() {
        guard !busy, !apps.isEmpty else { return }
        let region = country.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard region.count == 2, Locale.Region.isoRegions.contains(where: { $0.identifier == region }) else {
            status = "Enter a two-letter App Store region, such as US, GB or ZA."
            return
        }
        country = region
        busy = true
        updates = [:]
        let snapshot = selected.isEmpty ? apps : apps.filter { selected.contains($0.id) }
        task = Task {
            defer {
                for (id, state) in updates where state == .checking { updates[id] = .notChecked }
                busy = false
                task = nil
            }
            do {
                // The Homebrew catalog is one large download, fetched once for all website apps.
                var catalog: [CaskRelease] = []
                var catalogError: String?
                if snapshot.contains(where: { $0.source == .developer }) {
                    status = "Fetching the Homebrew app catalog…"
                    do {
                        catalog = try await lookup.catalog()
                    } catch {
                        try Task.checkCancellation()
                        catalogError = error.localizedDescription
                    }
                }
                var hasQueriedStore = false
                for (index, app) in snapshot.enumerated() {
                    try Task.checkCancellation()
                    updates[app.id] = .checking
                    status = "Checking \(index + 1) of \(snapshot.count): \(app.name)"
                    switch app.source {
                    case .system:
                        updates[app.id] = .unknown("Apple app: updates come from macOS Software Update or Apple’s own download.")
                    case .developer:
                        var state = catalogError.map { .failed("Homebrew catalog: \($0)") }
                            ?? UpdateLookup.caskResult(app, releases: catalog)
                        // Not in Homebrew: fall back to the app's own Sparkle update feed.
                        if app.feedURL != nil, !state.isAvailable, !Self.isCurrent(state) {
                            do {
                                state = try await lookup.checkSparkle(app)
                            } catch {
                                try Task.checkCancellation()
                            }
                        }
                        updates[app.id] = state
                    case .appStore:
                        // Apple's public lookup API is rate limited; keep requests below 20/minute.
                        if hasQueriedStore { try await Task.sleep(for: .milliseconds(3100)) }
                        hasQueriedStore = true
                        do {
                            updates[app.id] = try await lookup.checkStore(app, country: region)
                        } catch {
                            try Task.checkCancellation()
                            updates[app.id] = .failed("App Store: \(error.localizedDescription)")
                        }
                    }
                }
                let unknown = updates.values.filter {
                    switch $0 { case .unknown, .failed: true; default: false }
                }.count
                let available = updates.values.filter(\.isAvailable).count
                status = "\(available) updates found · \(unknown) apps could not be verified."
            } catch {
                status = "Update check cancelled. Completed results are shown."
            }
        }
    }

    // MARK: Installing updates
    /// Downloads and installs updates one app at a time, showing installer progress per row.
    func install(_ targets: [InstalledApp]) {
        guard !busy, !targets.isEmpty else { return }
        busy = true
        task = Task {
            defer { busy = false; task = nil }
            var installed = 0
            for (index, app) in targets.enumerated() {
                guard !Task.isCancelled, let original = updates[app.id],
                      case .available(_, let destination, _, let method) = original, method != .manual else { continue }
                status = "Updating \(index + 1) of \(targets.count): \(app.name)…"
                updates[app.id] = .updating("Starting…")
                let id = app.id
                do {
                    let newVersion = try await updater.install(app, method: method) { line in
                        Task { @MainActor in
                            // Ignore late output once the row has finished.
                            if case .updating? = self.updates[id] { self.updates[id] = .updating(String(line.prefix(120))) }
                        }
                    }
                    // Only report success if the version on disk actually changed.
                    guard let newVersion, newVersion != app.version else {
                        throw Shell.Failure("The installer finished but the app is still version \(app.version ?? "unknown").")
                    }
                    updates[id] = .updated(newVersion)
                    replaceVersion(of: app, with: newVersion)
                    installed += 1
                } catch is CancellationError {
                    updates[id] = original                 // still available; nothing was installed
                } catch {
                    updates[id] = .updateFailed(error.localizedDescription, destination: destination)
                }
            }
            status = Task.isCancelled
                ? "Updates stopped. \(installed) installed."
                : "\(installed) of \(targets.count) updates installed."
        }
    }

    private func replaceVersion(of app: InstalledApp, with version: String) {
        guard let index = apps.firstIndex(where: { $0.id == app.id }) else { return }
        apps[index] = InstalledApp(url: app.url, name: app.name, bundleID: app.bundleID,
                                   version: version, source: app.source, feedURL: app.feedURL)
    }

    private static func isCurrent(_ state: AppUpdateState) -> Bool {
        if case .current = state { return true }
        return false
    }

    func cancel() { task?.cancel() }

    func openPage(_ url: URL) {
        if !NSWorkspace.shared.open(url) { status = "Could not open \(url.absoluteString)." }
    }

    func toggle(_ app: InstalledApp) {
        guard !busy else { return }
        if selected.contains(app.id) { selected.remove(app.id) } else { selected.insert(app.id) }
    }
}

// MARK: - Applications page
struct InstalledAppsView: View {
    @Bindable var model: InstalledAppsModel
    let manageApps: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Applications", symbol: "square.stack.3d.up.fill",
                       subtitle: "Discover installed apps, then install available updates automatically.")

            // Scan / check / update toolbar.
            HStack {
                Button("Scan Apps", systemImage: "magnifyingglass") { model.scan() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy)
                    .accessibilityIdentifier("scan-installed-apps")
                Button("Check for Updates", systemImage: "arrow.triangle.2.circlepath") { model.checkUpdates() }
                    .disabled(model.busy || model.apps.isEmpty)
                    .accessibilityIdentifier("check-app-updates")
                    .help(model.selected.isEmpty ? "Check all apps" : "Check selected apps")
                // Appears once there's something to update.
                if !model.updatableApps.isEmpty {
                    let targets = model.updateTargets
                    Button(targets.count == model.updatableApps.count ? "Update All (\(targets.count))" : "Update Selected (\(targets.count))",
                           systemImage: "arrow.down.circle.fill") { model.install(targets) }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .disabled(model.busy)
                        .accessibilityIdentifier("update-all-apps")
                }
                if model.busy {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { model.cancel() }
                }
                Spacer()
                Text("\(model.apps.count) apps").foregroundStyle(.secondary)
            }

            HStack {
                TextField("Search apps", text: $model.search)
                    .textFieldStyle(.roundedBorder)
                Text("Store region").font(.caption)
                TextField("US", text: $model.country)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 48)
                    .disabled(model.busy)
                    .accessibilityLabel("App Store country code")
            }

            if model.apps.isEmpty {
                ContentUnavailableView("Find your installed apps", systemImage: "app.dashed",
                                       description: Text(model.status))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.visibleApps) { app in appRow(app) }
                    .listStyle(.inset)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("app-scan-status")
            if !model.scanWarnings.isEmpty {
                DisclosureGroup("Locations that couldn’t be read (\(model.scanWarnings.count))") {
                    ScrollView {
                        Text(model.scanWarnings.joined(separator: "\n"))
                            .font(.caption).textSelection(.enabled)
                    }.frame(maxHeight: 70)
                }
            }

            HStack {
                Button("Include Folder…") { model.includeFolder() }.disabled(model.busy)
                Button("Select Visible") { model.selected.formUnion(model.visibleApps.map(\.id)) }.disabled(model.busy)
                Button("Clear Selection") { model.selected = [] }.disabled(model.busy || model.selected.isEmpty)
                Text("\(model.selected.count) selected").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Manage / Uninstall…", action: manageApps).disabled(model.busy)
            }
            .font(.callout)
        }
        .padding(28)
    }

    // MARK: App row
    /// Clicking anywhere on the row (outside its buttons) selects the app.
    private func appRow(_ app: InstalledApp) -> some View {
        let state = model.updates[app.id] ?? .notChecked
        let isSelected = model.selected.contains(app.id)
        return HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? .purple : .secondary)
                .accessibilityLabel(isSelected ? "Selected" : "Not selected")
            FileIcon.image(for: app.url.path)
                .resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name).font(.headline)
                Text("\(app.version ?? "Version unknown") · \(app.source.rawValue)")
                    .font(.caption).foregroundStyle(.secondary)
                Text(app.url.path)
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                Text(state.label)
                    .font(.caption)
                    .foregroundStyle(stateColor(state))
                    .help(state.detail)
                stateAccessory(app, state: state)
            }
            Button { NSWorkspace.shared.activateFileViewerSelecting([app.url]) } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal \(app.name) in Finder")
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture { model.toggle(app) }
        .listRowBackground(isSelected ? Color.purple.opacity(0.16) : Color.clear)
    }

    /// Update button, live installer output, or a fallback link depending on state.
    @ViewBuilder
    private func stateAccessory(_ app: InstalledApp, state: AppUpdateState) -> some View {
        switch state {
        case .available(_, let destination, _, .manual):
            Button("Download") { model.openPage(destination) }
                .controlSize(.small)
                .help("Opens the developer’s download. Install it, then check again.")
                .accessibilityLabel("Download update for \(app.name)")
        case .available:
            Button("Update") { model.install([app]) }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy)
                .accessibilityLabel("Update \(app.name)")
        case .updating(let line):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(line).font(.caption2).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 220, alignment: .trailing)
            }
        case .updateFailed(let reason, let destination):
            Button("Open Download Page") { model.openPage(destination) }
                .controlSize(.small)
                .help(reason)
        case .checking:
            ProgressView().controlSize(.small)
        default:
            EmptyView()
        }
    }

    private func stateColor(_ state: AppUpdateState) -> Color {
        switch state {
        case .available, .updated: .green
        case .updateFailed, .failed: .red
        default: .secondary
        }
    }
}

#Preview("Installed Apps") {
    InstalledAppsView(model: InstalledAppsModel(), manageApps: {})
        .frame(width: 720, height: 620)
}
