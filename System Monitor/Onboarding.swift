import SwiftUI
import AppKit
import ServiceManagement
import Observation
import Darwin

// MARK: - Permission state
/// Tracks the permissions System Monitor uses (Login Item, Full Disk Access, App Management,
/// and CleanMyMac-style user-authorized Security-Scoped Bookmarks for App Store sandbox compliance).
@MainActor
@Observable
final class PermissionCenter {
    static let shared = PermissionCenter()

    enum Status { case unknown, granted, denied }

    private(set) var loginItemEnabled = false
    private(set) var fullDiskAccess = false
    private(set) var folderAccessGranted = false
    private(set) var authorizedFolders: [URL] = []
    private(set) var appManagement: Status = .unknown

    @ObservationIgnored private var activeSecurityScopedURLs: [URL] = []

    /// Deep links that open the exact System Settings panes.
    private static let fullDiskAccessPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    private static let appManagementPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")!

    /// True when the app is running inside the Mac App Store / macOS App Sandbox.
    nonisolated static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    /// The user's real home folder (`/Users/<name>`), bypassing the sandbox container path
    /// (`~/Library/Containers/<bundle-id>/Data`) returned by `FileManager.default.homeDirectoryForCurrentUser`.
    nonisolated static var realHomeDirectory: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Ready once Full Disk Access or Home Folder Access is on and App Management isn't known to be blocked.
    var diskAccessReady: Bool { fullDiskAccess || folderAccessGranted }
    var essentialsGranted: Bool { diskAccessReady && appManagement != .denied }
    var allGranted: Bool { loginItemEnabled && essentialsGranted }

    /// Cheap checks, polled every second while onboarding is visible.
    func refresh() {
        loginItemEnabled = SMAppService.mainApp.status == .enabled
        fullDiskAccess = Self.hasFullDiskAccess()
        folderAccessGranted = fullDiskAccess || hasAuthorizedAccess(to: Self.realHomeDirectory)
    }

    // MARK: Security-Scoped Bookmarks
    /// Restores all persisted security-scoped bookmarks on launch so previously authorized
    /// folders (such as the user's Home directory, Macintosh HD, or /Applications) stay accessible.
    func restoreSavedAccess() {
        let defaults = UserDefaults.standard
        guard let stored = defaults.dictionary(forKey: DefaultsKey.securityBookmarks) as? [String: Data] else {
            refresh()
            return
        }
        var updated = stored
        var resolvedURLs: [URL] = []
        for (path, data) in stored {
            var isStale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                                     relativeTo: nil, bookmarkDataIsStale: &isStale) else { continue }
            if isStale, let fresh = try? url.bookmarkData(options: [.withSecurityScope],
                                                          includingResourceValuesForKeys: nil, relativeTo: nil) {
                updated[path] = fresh
            }
            if !activeSecurityScopedURLs.contains(url) {
                if url.startAccessingSecurityScopedResource() {
                    activeSecurityScopedURLs.append(url)
                }
            }
            resolvedURLs.append(url.standardizedFileURL)
        }
        if updated != stored {
            defaults.set(updated, forKey: DefaultsKey.securityBookmarks)
        }
        authorizedFolders = resolvedURLs.sorted { $0.path < $1.path }
        refresh()
    }

    /// Releases active security-scoped resources on app termination.
    func stopAccessingAll() {
        for url in activeSecurityScopedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        activeSecurityScopedURLs.removeAll()
    }

    /// Persists a security-scoped bookmark for `url` and begins accessing it immediately.
    func saveBookmark(for url: URL) {
        let standardized = url.standardizedFileURL
        if !activeSecurityScopedURLs.contains(standardized) {
            if standardized.startAccessingSecurityScopedResource() {
                activeSecurityScopedURLs.append(standardized)
            }
        }
        let defaults = UserDefaults.standard
        var stored = (defaults.dictionary(forKey: DefaultsKey.securityBookmarks) as? [String: Data]) ?? [:]
        if let data = try? standardized.bookmarkData(options: [.withSecurityScope],
                                                     includingResourceValuesForKeys: nil, relativeTo: nil) {
            stored[standardized.path] = data
            defaults.set(stored, forKey: DefaultsKey.securityBookmarks)
        }
        if !authorizedFolders.contains(standardized) {
            authorizedFolders.append(standardized)
            authorizedFolders.sort { $0.path < $1.path }
        }
        refresh()
    }

    /// Presents an Open Panel (like CleanMyMac on the Mac App Store) so the user can grant
    /// System Monitor access to their Home folder, Macintosh HD, or Applications folder.
    @discardableResult
    func grantFolderAccess(startingAt directory: URL? = nil,
                           message: String? = nil,
                           completion: (@MainActor (Bool) -> Void)? = nil) -> Bool {
        let panel = NSOpenPanel()
        panel.title = "Grant Disk Access"
        panel.message = message ?? "Select your Home folder (\(Self.realHomeDirectory.lastPathComponent)) or Macintosh HD to let System Monitor scan for junk, large files, and app leftovers."
        panel.prompt = "Grant Access"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.showsHiddenFiles = false
        panel.directoryURL = directory ?? Self.realHomeDirectory

        NSApp.activate(ignoringOtherApps: true)
        if let completion {
            panel.begin { [weak self] response in
                guard let self else { return }
                let granted = response == .OK && !panel.urls.isEmpty
                if granted {
                    for url in panel.urls { self.saveBookmark(for: url) }
                }
                completion(granted)
            }
            return false
        } else {
            let response = panel.runModal()
            guard response == .OK, !panel.urls.isEmpty else { return false }
            for url in panel.urls { saveBookmark(for: url) }
            return true
        }
    }

    /// True if `target` (or an ancestor folder such as `/`) has been authorized or is readable.
    func hasAuthorizedAccess(to target: URL) -> Bool {
        let targetPath = target.resolvingSymlinksInPath().standardizedFileURL.path
        let coveredByBookmark = authorizedFolders.contains { folder in
            let folderPath = folder.resolvingSymlinksInPath().standardizedFileURL.path
            return folderPath == "/" || targetPath == folderPath || targetPath.hasPrefix(folderPath + "/")
        }
        if coveredByBookmark { return true }
        let library = Self.realHomeDirectory.appendingPathComponent("Library/Caches")
        return (try? FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)) != nil
    }

    // MARK: Open at Login
    /// Registers the app as a login item, then opens Login Items settings so the
    /// user can confirm (or approve it if macOS requires approval).
    func enableLoginItem() {
        try? SMAppService.mainApp.register()
        SMAppService.openSystemSettingsLoginItems()
        refresh()
    }

    // MARK: Full Disk Access
    func openFullDiskAccess() { NSWorkspace.shared.open(Self.fullDiskAccessPane) }

    /// The user's TCC database is only readable with Full Disk Access, and reading
    /// it never triggers a prompt, so it's a safe yes/no test.
    nonisolated static func hasFullDiskAccess() -> Bool {
        let database = realHomeDirectory
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        guard let handle = try? FileHandle(forReadingFrom: database) else { return false }
        try? handle.close()
        return true
    }

    // MARK: App Management
    /// Probes once, which also makes macOS list System Monitor under
    /// Privacy & Security › App Management, then opens that pane.
    func requestAppManagement() async {
        await checkAppManagement()
        if appManagement != .granted { NSWorkspace.shared.open(Self.appManagementPane) }
    }

    func checkAppManagement() async {
        appManagement = await Task.detached(priority: .userInitiated) { Self.probeAppManagement() }.value
    }

    func openAppManagement() { NSWorkspace.shared.open(Self.appManagementPane) }

    /// Writes and immediately removes an empty marker file at the root of a
    /// third-party app bundle the user owns. Without App Management macOS blocks
    /// the write (EPERM) even though normal file permissions allow it.
    nonisolated static func probeAppManagement() -> Status {
        let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard let apps = try? FileManager.default.contentsOfDirectory(at: applications, includingPropertiesForKeys: nil) else {
            return .unknown
        }
        let candidate = apps.first { url in
            guard url.pathExtension == "app", Darwin.access(url.path, W_OK) == 0,
                  let identifier = Bundle(url: url)?.bundleIdentifier else { return false }
            return !identifier.hasPrefix("com.apple.") && identifier != Bundle.main.bundleIdentifier
        }
        guard let candidate else { return .unknown }      // nothing user-owned to test with
        let marker = candidate.appendingPathComponent(".system-monitor-access-check")
        do {
            try Data().write(to: marker)
            try? FileManager.default.removeItem(at: marker)
            return .granted
        } catch {
            return CleanupService.isPermissionError(error) ? .denied : .unknown
        }
    }

    // MARK: Restart
    /// Relaunches the app using public `NSWorkspace` APIs (App Store & Sandbox compliant)
    /// with a flag asking the new instance to verify permissions.
    func restartAndVerify() {
        UserDefaults.standard.set(true, forKey: DefaultsKey.pendingVerification)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--verify-permissions"]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in
                NSApp.terminate(nil)
            }
        }
    }
}

/// UserDefaults keys for onboarding progress and persisted security-scoped bookmarks.
enum DefaultsKey {
    static let onboardingCompleted = "onboardingCompleted"
    static let onboardingPage = "onboardingPage"
    static let pendingVerification = "pendingPermissionVerification"
    static let securityBookmarks = "securityScopedBookmarks"
}

// MARK: - disk access banner
/// Reusable banner shown on cleanup and storage pages when full disk or folder access hasn't been granted yet.
struct DiskAccessBanner: View {
    var startingFolder: URL = PermissionCenter.realHomeDirectory
    var onGranted: (() -> Void)? = nil
    private var permissions = PermissionCenter.shared

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.fill.badge.checkmark")
                .font(.title2)
                .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text("Grant Disk Access for Complete Scanning")
                    .font(.subheadline.weight(.semibold))
                Text("Authorize your Home folder or enable Full Disk Access so System Monitor can reach caches, Trash, and browser data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Grant Folder Access…") {
                permissions.grantFolderAccess(startingAt: startingFolder) { granted in
                    if granted { onGranted?() }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Button("Full Disk Access Settings") {
                permissions.openFullDiskAccess()
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.purple.opacity(0.2)))
    }
}

// MARK: - Onboarding slides
enum OnboardingPage: Int, CaseIterable {
    case loginItem, fullDiskAccess, appManagement, finish
}

struct OnboardingView: View {
    @State private var page: OnboardingPage
    @State private var countdown: Int?
    @State private var countdownTask: Task<Void, Never>?
    private let verifying: Bool
    private let permissions = PermissionCenter.shared
    let close: () -> Void

    init(startAt page: OnboardingPage, verifying: Bool, close: @escaping () -> Void) {
        _page = State(initialValue: page)
        self.verifying = verifying
        self.close = close
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case .loginItem: loginSlide
                case .fullDiskAccess: fullDiskSlide
                case .appManagement: appManagementSlide
                case .finish: finishSlide
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.push(from: .trailing))
            .id(page)

            Divider()
            footer.padding(20)
        }
        .frame(width: 560, height: 500)
        .animation(.easeInOut(duration: 0.3), value: page)
        .task {
            // Poll the cheap checks once a second so status badges update live.
            if verifying { await permissions.checkAppManagement() }
            while !Task.isCancelled {
                permissions.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onChange(of: page) { _, newPage in
            UserDefaults.standard.set(newPage.rawValue, forKey: DefaultsKey.onboardingPage)
            if newPage == .finish, !verifying, permissions.essentialsGranted { startCountdown() }
        }
        .onChange(of: permissions.fullDiskAccess) { _, granted in
            // Move on automatically once the user flips the switch in System Settings.
            if granted, page == .fullDiskAccess { page = .appManagement }
        }
        .onDisappear { countdownTask?.cancel() }
    }

    // MARK: Slides
    private var loginSlide: some View {
        slide(symbol: "power.circle.fill", title: "Open at Login",
              text: "Start System Monitor automatically when you log in, so live readings are always in your menu bar.",
              granted: permissions.loginItemEnabled,
              action: ("Open Login Items Settings", { permissions.enableLoginItem() }))
    }

    private var fullDiskSlide: some View {
        slide(symbol: "externaldrive.fill.badge.checkmark", title: "Full Disk & Folder Access",
              text: "Grant access to your Home folder or Macintosh HD to scan caches, large files, and leftovers — and optionally turn on Full Disk Access in System Settings for Trash, Safari, and recent items.",
              granted: permissions.diskAccessReady,
              action: ("Grant Folder Access…", {
                  permissions.grantFolderAccess(startingAt: PermissionCenter.realHomeDirectory) { _ in }
              }),
              secondaryAction: ("Open Full Disk Access Settings", { permissions.openFullDiskAccess() }))
    }

    private var appManagementSlide: some View {
        slide(symbol: "app.badge.checkmark.fill", title: "App Management",
              text: "Lets System Monitor uninstall and update other apps.\n\nAuthorize your Applications folder and switch on System Monitor under Privacy & Security › App Management.",
              granted: permissions.appManagement == .granted,
              action: ("Open App Management Settings", { Task { await permissions.requestAppManagement() } }),
              secondaryAction: ("Authorize Applications Folder…", {
                  permissions.grantFolderAccess(startingAt: URL(fileURLWithPath: "/Applications")) { _ in }
              }))
    }

    private var finishSlide: some View {
        VStack(spacing: 18) {
            Image(systemName: permissions.allGranted ? "checkmark.seal.fill" : "exclamationmark.shield.fill")
                .font(.system(size: 56))
                .foregroundStyle(permissions.allGranted ? .green : .orange)
            Text(finishTitle).font(.title.bold())
            VStack(alignment: .leading, spacing: 10) {
                statusRow("Open at Login", granted: permissions.loginItemEnabled) { permissions.enableLoginItem() }
                statusRow("Folder Access (Home / Disk)", granted: permissions.folderAccessGranted, buttonTitle: "Grant Access") {
                    permissions.grantFolderAccess(startingAt: PermissionCenter.realHomeDirectory) { _ in }
                }
                statusRow("Full Disk Access", granted: permissions.fullDiskAccess) { permissions.openFullDiskAccess() }
                statusRow("App Management", granted: permissions.appManagement == .granted) { permissions.openAppManagement() }
            }
            .padding(16)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            if let countdown {
                Text("System Monitor will restart in \(countdown) second\(countdown == 1 ? "" : "s") to apply permissions.")
                    .font(.headline)
                    .foregroundStyle(.purple)
                    .contentTransition(.numericText())
            } else if verifying && !permissions.allGranted {
                Text("Some permissions are still off. Turn them on, then restart to check again.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(32)
    }

    private var finishTitle: String {
        if verifying { return permissions.allGranted ? "You’re all set" : "Almost there" }
        return permissions.essentialsGranted ? "Permissions granted" : "Finish setting up"
    }

    private func slide(symbol: String, title: String, text: String, granted: Bool,
                       action: (String, () -> Void),
                       secondaryAction: (String, () -> Void)? = nil) -> some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 60))
                .foregroundStyle(.purple)
                .symbolRenderingMode(.hierarchical)
            Text(title).font(.title.bold())
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            HStack(spacing: 12) {
                Button(action.0, action: action.1)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                if let secondaryAction {
                    Button(secondaryAction.0, action: secondaryAction.1)
                        .controlSize(.large)
                }
            }
            Label(granted ? "Granted" : "Not granted yet",
                  systemImage: granted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(granted ? .green : .secondary)
                .font(.callout.weight(.medium))
        }
        .padding(32)
    }

    private func statusRow(_ title: String, granted: Bool, buttonTitle: String = "Open Settings", fix: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .red)
            Text(title)
            Spacer(minLength: 24)
            if !granted { Button(buttonTitle, action: fix).controlSize(.small) }
        }
        .frame(width: 340)
    }

    // MARK: Footer navigation
    private var footer: some View {
        HStack {
            // Page dots.
            HStack(spacing: 6) {
                ForEach(OnboardingPage.allCases, id: \.self) { item in
                    Circle()
                        .fill(item == page ? Color.purple : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            Spacer()
            if page == .finish {
                finishButtons
            } else {
                if page != .loginItem {
                    Button("Back") { page = OnboardingPage(rawValue: page.rawValue - 1) ?? .loginItem }
                }
                Button("Continue") { page = OnboardingPage(rawValue: page.rawValue + 1) ?? .finish }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder
    private var finishButtons: some View {
        if countdown != nil {
            Button("Cancel") { countdownTask?.cancel(); countdown = nil }
            Button("Restart Now") { permissions.restartAndVerify() }
                .keyboardShortcut(.defaultAction)
        } else if verifying && permissions.allGranted {
            Button("Open Dashboard") { complete(); WindowCoordinator.shared.showDashboard() }
                .keyboardShortcut(.defaultAction)
        } else {
            Button("Skip for Now") { complete() }
            Button("Restart & Check") { startCountdown() }
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Countdown
    /// Shows a 5-second countdown, then relaunches to verify the permissions.
    private func startCountdown() {
        countdownTask?.cancel()
        countdownTask = Task {
            for remaining in stride(from: 5, through: 1, by: -1) {
                countdown = remaining
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
            permissions.restartAndVerify()
        }
    }

    private func complete() {
        UserDefaults.standard.set(true, forKey: DefaultsKey.onboardingCompleted)
        close()
    }
}
