import AppKit

// MARK: - App updater
/// Downloads and installs updates without opening a browser:
/// • Website apps: Homebrew (`brew upgrade --cask`, or a forced install that adopts
///   apps that weren't installed with brew).
/// • App Store apps: the `mas` command-line tool (installed via Homebrew if missing).
/// Running apps are quit first and reopened afterwards.
actor AppUpdater {
    /// Installs the update and returns the version now on disk.
    func install(_ app: InstalledApp, method: UpdateMethod,
                 progress: @escaping @Sendable (String) -> Void) async throws -> String? {
        let signerBefore = CodeSigner.read(atPath: app.url.path)
        let wasRunning = await Self.quit(bundleID: app.bundleID)
        do {
            switch method {
            case .homebrew(let token): try await installCask(token, progress: progress)
            case .appStore(let trackID): try await installFromStore(trackID, progress: progress)
            case .manual: throw Shell.Failure("This update has to be downloaded from the developer.")
            }
        } catch {
            if wasRunning { await Self.reopen(app.url) }
            throw error
        }
        let version = InstalledAppScanner.version(at: app.url)
        // The new copy must be validly signed by the same developer as the old one.
        // Otherwise don't reopen it and report the problem.
        try Self.verifySignature(at: app.url, matches: signerBefore)
        if wasRunning { await Self.reopen(app.url) }
        return version
    }

    static func verifySignature(at url: URL, matches before: CodeSigner?) throws {
        guard let before else { return }                      // nothing to compare against
        guard let after = CodeSigner.read(atPath: url.path) else {
            throw Shell.Failure("The updated app’s code signature is missing or invalid. Don’t open it; download it from the developer instead.")
        }
        if before.isApple != after.isApple || before.teamID != after.teamID {
            throw Shell.Failure("The updated app is signed by “\(after.name)” instead of “\(before.name)”. Check it before opening.")
        }
    }

    // MARK: Homebrew
    private func installCask(_ token: String, progress: @escaping @Sendable (String) -> Void) async throws {
        if PermissionCenter.isSandboxed {
            throw Shell.Failure("Automatic Homebrew updates are restricted in the App Sandbox. Use Open Download Page to install the update.")
        }
        guard let brew = Shell.brew else {
            throw Shell.Failure("Homebrew isn’t installed. Install it from brew.sh to update website apps automatically.")
        }
        // Installers that need root show a password dialog via this helper.
        let environment = ["SUDO_ASKPASS": try Shell.askpassScript().path]
        progress("Checking Homebrew…")
        let managed = try await Shell.run(brew, ["list", "--cask", token]).succeeded
        // --greedy also upgrades casks that normally update themselves; --force lets
        // brew replace a copy that was installed from the developer's website.
        let arguments = managed
            ? ["upgrade", "--cask", "--greedy", token]
            : ["install", "--cask", "--force", token]
        let result = try await Shell.run(brew, arguments, environment: environment, onLine: progress)
        guard result.succeeded else { throw Shell.Failure("Homebrew: \(result.message)") }
    }

    // MARK: Mac App Store
    private func installFromStore(_ trackID: Int, progress: @escaping @Sendable (String) -> Void) async throws {
        if PermissionCenter.isSandboxed {
            if let storeURL = URL(string: "macappstore://itunes.apple.com/app/id\(trackID)") {
                _ = await MainActor.run { NSWorkspace.shared.open(storeURL) }
            }
            throw Shell.Failure("Opened in the Mac App Store to complete the update.")
        }
        let mas = try await masTool(progress: progress)
        progress("Downloading from the App Store…")
        let result = try await Shell.run(mas, ["upgrade", String(trackID)], onLine: progress)
        if result.succeeded { return }
        // Recent mas versions need root to install; ask once for the admin password.
        progress("Waiting for administrator approval…")
        let elevated = try await Shell.runAsAdministrator(
            "\(Shell.quote(mas.path)) upgrade \(trackID)",
            prompt: "System Monitor needs your password to install an App Store update.")
        guard elevated.succeeded else { throw Shell.Failure("App Store: \(elevated.message)") }
    }

    /// Returns the mas tool, installing it with Homebrew on first use.
    private func masTool(progress: @escaping @Sendable (String) -> Void) async throws -> URL {
        if let mas = Shell.tool("mas") { return mas }
        guard let brew = Shell.brew else {
            throw Shell.Failure("Homebrew isn’t installed, so App Store updates can’t be automated. Install it from brew.sh.")
        }
        progress("Installing the mas App Store tool…")
        let result = try await Shell.run(brew, ["install", "mas"], onLine: progress)
        guard result.succeeded, let mas = Shell.tool("mas") else { throw Shell.Failure("Couldn’t install mas: \(result.message)") }
        return mas
    }

    // MARK: Quitting & reopening
    /// Quits a running app so its bundle can be replaced; returns whether it was running.
    @MainActor
    private static func quit(bundleID: String?) async -> Bool {
        guard let bundleID else { return false }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard !running.isEmpty else { return false }
        await RunningApps.quit(running)
        return true
    }

    @MainActor
    private static func reopen(_ url: URL) async {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}

// MARK: - Quitting running apps
@MainActor
enum RunningApps {
    /// Asks the apps to quit and gives them up to 10 seconds to save and close.
    /// Returns true once all of them have terminated.
    @discardableResult
    static func quit(_ running: [NSRunningApplication]) async -> Bool {
        running.forEach { $0.terminate() }
        for _ in 0..<50 where running.contains(where: { !$0.isTerminated }) {
            try? await Task.sleep(for: .milliseconds(200))
        }
        return running.allSatisfy(\.isTerminated)
    }
}
