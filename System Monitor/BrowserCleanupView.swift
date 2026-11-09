import SwiftUI
import AppKit
import Observation

// MARK: - Browser cleanup model
@MainActor
@Observable
final class BrowserCleanupModel {
    var installed: [BrowserDefinition] = []
    var working: String?                       // browser id currently being cleaned
    var message: String?
    var isError = false
    @ObservationIgnored private let cleaner = BrowserCleaner()

    /// Finds supported browsers that are installed.
    func scan() {
        installed = BrowserDefinition.supported.filter {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil
        }
    }

    func isRunning(_ browser: BrowserDefinition) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: browser.id).isEmpty
    }

    /// Quits the browser if needed (its databases are locked while open), then clears data.
    func clear(_ data: BrowserData, in browser: BrowserDefinition) {
        guard working == nil else { return }
        working = browser.id
        message = nil
        Task {
            defer { working = nil }
            guard await quit(browser) else {
                report("\(browser.name) didn’t quit. Close it and try again.", error: true)
                return
            }
            let outcome = await cleaner.clear(data, in: browser)
            if !outcome.errors.isEmpty {
                report("\(browser.name): \(outcome.errors.joined(separator: "; "))", error: true)
            } else if outcome.profiles == 0 {
                report("No \(data.rawValue.lowercased()) found for \(browser.name).", error: false)
            } else {
                report("\(data.rawValue) cleared for \(browser.name)"
                       + (outcome.profiles > 1 ? " (\(outcome.profiles) profiles)." : "."), error: false)
            }
        }
    }

    private func report(_ text: String, error: Bool) {
        message = text
        isError = error
    }

    /// Asks the browser to quit and waits up to 10 seconds for it to close.
    private func quit(_ browser: BrowserDefinition) async -> Bool {
        await RunningApps.quit(NSRunningApplication.runningApplications(withBundleIdentifier: browser.id))
    }
}

// MARK: - Browsers page
struct BrowserCleanupView: View {
    @State private var model = BrowserCleanupModel()
    @State private var pending: (data: BrowserData, browser: BrowserDefinition)?
    private var permissions = PermissionCenter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "Browsers", symbol: "globe",
                       subtitle: "Clear browsing history or cookies right here. Clearing cookies signs you out of websites. Bookmarks, passwords and settings are kept.")
            if !permissions.diskAccessReady || model.isError {
                DiskAccessBanner()
            }
            HStack {
                Button("Scan Browsers", systemImage: "arrow.clockwise") { model.scan() }
                    .disabled(model.working != nil)
                Button("Grant Folder Access…") {
                    permissions.grantFolderAccess(startingAt: PermissionCenter.realHomeDirectory) { _ in }
                }
                .disabled(model.working != nil)
                Button("Full Disk Access Settings") {
                    permissions.openFullDiskAccess()
                }
            }

            if model.installed.isEmpty {
                ContentUnavailableView("No supported browsers found", systemImage: "globe")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.installed) { browser in row(browser) }
                    .listStyle(.inset)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            if let message = model.message {
                Label(message, systemImage: model.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(model.isError ? .red : .green)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background((model.isError ? Color.red : Color.green).opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .textSelection(.enabled)
            }
        }
        .padding(28)
        .task { model.scan() }
        // Confirm first: the browser is quit and the data can't be recovered.
        .alert(alertTitle, isPresented: Binding(isPresent: $pending)) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                if let pending { model.clear(pending.data, in: pending.browser) }
            }
        } message: {
            if let pending {
                Text((model.isRunning(pending.browser) ? "\(pending.browser.name) will quit first. " : "")
                     + "This can’t be undone. Synced history may also be removed from your other devices.")
            }
        }
    }

    private var alertTitle: String {
        guard let pending else { return "" }
        return "Clear \(pending.data.rawValue.lowercased()) in \(pending.browser.name)?"
    }

    private func row(_ browser: BrowserDefinition) -> some View {
        HStack {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.id) {
                FileIcon.image(for: url.path).resizable().frame(width: 28, height: 28)
            }
            Text(browser.name).font(.headline)
            Spacer()
            if model.working == browser.id {
                ProgressView().controlSize(.small)
            }
            Button("Clear History…") { pending = (.history, browser) }
            Button("Clear Cookies…") { pending = (.cookies, browser) }
        }
        .disabled(model.working != nil)
        .padding(.vertical, 8)
    }
}
