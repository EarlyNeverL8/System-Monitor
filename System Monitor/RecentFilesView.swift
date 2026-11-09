import SwiftUI
import AppKit
import Observation

// MARK: - Recent documents
struct RecentDocument: Identifiable {
    let url: URL
    let lastOpened: Date
    var id: URL { url }
}

// MARK: - Recent files model
/// Finds documents opened in the last 30 days using Spotlight's last-used dates.
@MainActor
@Observable
final class RecentFilesModel {
    var documents: [RecentDocument] = []
    var busy = false
    var status = ""
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Entries opened before this date are hidden ("Clear List" only affects this app).
    var clearedThrough: Date {
        defaults.object(forKey: "recentDocumentsClearedThrough") as? Date ?? .distantPast
    }

    func clearList() {
        defaults.set(Date(), forKey: "recentDocumentsClearedThrough")
        documents = []
        status = "List cleared in System Monitor. Original files and Finder’s Recents are unchanged."
    }

    func restoreList() {
        defaults.removeObject(forKey: "recentDocumentsClearedThrough")
    }

    /// Clears macOS's own recent-items lists (Apple menu › Recent Items and each
    /// app's File › Open Recent), then restarts the service that keeps them.
    func clearSystemRecents() async {
        let message = await Task.detached(priority: .userInitiated) { () -> String in
            let folder = PermissionCenter.realHomeDirectory
                .appendingPathComponent("Library/Application Support/com.apple.sharedfilelist")
            do {
                var targets = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                    .filter { ["RecentDocuments", "RecentApplications", "RecentServers"].contains(where: $0.lastPathComponent.contains) }
                let perApp = folder.appendingPathComponent("com.apple.LSSharedFileList.ApplicationRecentDocuments")
                targets += (try? FileManager.default.contentsOfDirectory(at: perApp, includingPropertiesForKeys: nil)) ?? []
                for target in targets { try FileManager.default.removeItem(at: target) }
                _ = try? await Shell.run(URL(fileURLWithPath: "/usr/bin/killall"), ["sharedfilelistd"])
                return "Cleared \(targets.count) recent-items lists. Apple menu › Recent Items and Open Recent menus are now empty."
            } catch {
                return CleanupService.isPermissionError(error)
                    ? "macOS blocked access. Turn on Full Disk Access or grant Home folder access for System Monitor, then try again."
                    : "Couldn’t clear recent items: \(error.localizedDescription)"
            }
        }.value
        status = message
    }

    func load() async {
        guard !busy else { return }
        busy = true
        let query = NSMetadataQuery()
        defer { query.stop(); busy = false }
        query.searchScopes = [PermissionCenter.realHomeDirectory, NSMetadataQueryUserHomeScope]
        let cutoff = max(clearedThrough, Date().addingTimeInterval(-30 * 24 * 60 * 60))
        query.predicate = NSPredicate(
            format: "%K > %@ AND (%K == %@) AND NOT (%K == %@)",
            NSMetadataItemLastUsedDateKey, cutoff as NSDate,
            NSMetadataItemContentTypeTreeKey, "public.content",
            NSMetadataItemContentTypeTreeKey, "com.apple.application-bundle"
        )
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemLastUsedDateKey, ascending: false)]
        guard query.start() else {
            status = "Spotlight could not start. Try again in a moment."
            return
        }
        do {
            // Wait up to 10 s for Spotlight's initial gather to finish.
            for _ in 0..<100 {
                try await Task.sleep(for: .milliseconds(100))
                if !query.isGathering { break }
            }
            try Task.checkCancellation()
            query.disableUpdates()
            documents = query.results.compactMap { value -> RecentDocument? in
                guard let item = value as? NSMetadataItem,
                      let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                      let opened = item.value(forAttribute: NSMetadataItemLastUsedDateKey) as? Date else { return nil }
                return RecentDocument(url: URL(fileURLWithPath: path), lastOpened: opened)
            }.prefix(500).map { $0 }
            status = "\(documents.count) indexed documents opened in the last 30 days."
            if query.isGathering { status += " Spotlight is still indexing; refresh for more results." }
            if documents.isEmpty { status += " Spotlight indexing can limit results." }
        } catch {
            status = "Recent-files scan cancelled."
        }
    }

}

// MARK: - Recent files page
struct RecentFilesView: View {
    @State private var model = RecentFilesModel()
    @State private var refreshID = UUID()
    @State private var confirmingSystemClear = false
    private var permissions = PermissionCenter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "Recent Files", symbol: "doc.badge.clock",
                       subtitle: "Recently opened documents from Spotlight, the index behind Finder searches. Clear List hides entries here only; it never deletes or moves your files. Finder’s Recents is a search view and is not cleared by this action.")
            if !permissions.diskAccessReady {
                DiskAccessBanner { refreshID = UUID() }
            }
            HStack {
                Button("Refresh") { refreshID = UUID() }.disabled(model.busy)
                Button("Grant Folder Access…") {
                    permissions.grantFolderAccess(startingAt: PermissionCenter.realHomeDirectory) { granted in
                        if granted { refreshID = UUID() }
                    }
                }
                .disabled(model.busy)
                Spacer()
                Button("Show Cleared Entries") { model.restoreList(); refreshID = UUID() }.disabled(model.busy)
                Button("Clear List") { model.clearList() }
                    .disabled(model.busy || model.documents.isEmpty)
                    .accessibilityIdentifier("clear-recent-list")
                Button("Clear macOS Recent Items…") { confirmingSystemClear = true }
                    .disabled(model.busy)
            }
            if model.busy {
                ProgressView("Finding recently opened documents…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.documents.isEmpty {
                ContentUnavailableView("No recent documents to show", systemImage: "doc.badge.clock",
                                       description: Text(model.status))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.documents) { document in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(document.url.lastPathComponent)
                            Text(document.url.deletingLastPathComponent().path)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(document.lastOpened.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([document.url]) }
                    }
                }
                .listStyle(.inset)
                Text(model.status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(28)
        .task(id: refreshID) { await model.load() }
        .alert("Clear macOS recent items?", isPresented: $confirmingSystemClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) { Task { await model.clearSystemRecents() } }
        } message: {
            Text("Empties Apple menu › Recent Items and every app’s Open Recent menu. Your files aren’t touched.")
        }
    }
}
