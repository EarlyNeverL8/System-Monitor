import SwiftUI
import AppKit

// MARK: - App entry point
/// A menu-bar-only app (LSUIElement); windows are created on demand by WindowCoordinator.
@main
struct SystemMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

// MARK: - App lifecycle
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        PermissionCenter.shared.restoreSavedAccess()
        MonitorModel.shared.start()
        AlertCenter.shared.start()
        menuBar = MenuBarController()
        showOnboardingIfNeeded()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MonitorModel.shared.stop()
        MonitorModel.shared.saveHistory()
        PermissionCenter.shared.stopAccessingAll()
        menuBar?.shutdown()
    }

    /// First launch shows the permission slides; a relaunch after granting
    /// permissions (flagged by --verify-permissions) shows the verification summary.
    private func showOnboardingIfNeeded() {
        let arguments = ProcessInfo.processInfo.arguments
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        guard !isTesting, !arguments.contains("--skip-onboarding") else { return }

        let defaults = UserDefaults.standard
        if arguments.contains("--verify-permissions") || defaults.bool(forKey: DefaultsKey.pendingVerification) {
            defaults.set(false, forKey: DefaultsKey.pendingVerification)
            Task {
                let permissions = PermissionCenter.shared
                permissions.refresh()
                await permissions.checkAppManagement()
                if permissions.allGranted { defaults.set(true, forKey: DefaultsKey.onboardingCompleted) }
                WindowCoordinator.shared.showOnboarding(startAt: .finish, verifying: true)
            }
        } else if !defaults.bool(forKey: DefaultsKey.onboardingCompleted) {
            // Resume where the user left off (macOS may quit the app when FDA is toggled).
            let page = OnboardingPage(rawValue: defaults.integer(forKey: DefaultsKey.onboardingPage)) ?? .loginItem
            WindowCoordinator.shared.showOnboarding(startAt: page)
        }
    }
}
