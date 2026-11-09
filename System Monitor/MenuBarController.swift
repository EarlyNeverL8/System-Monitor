import AppKit
import SwiftUI

// MARK: - Menu bar item & hover popover
/// Shows live readings in a popover when the pointer hovers over the menu bar
/// icon; clicking pins it open. The popover's SwiftUI view only exists while it's
/// shown, so a closed popover costs no memory or redraws.
@MainActor
final class MenuBarController: NSResponder, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var trackingArea: NSTrackingArea?
    private var dismissalTask: Task<Void, Never>?
    private var hoverTask: Task<Void, Never>?
    private var pinned = false

    override init() {
        super.init()
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "System Monitor")
        button.image?.isTemplate = true
        button.setAccessibilityLabel("System Monitor")
        button.setAccessibilityIdentifier("system-monitor-status")
        button.setAccessibilityHelp("Hover for readings. Click to keep the panel open.")
        button.target = self
        button.action = #selector(togglePopover)
        let tracking = NSTrackingArea(rect: .zero,
                                      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
        button.addTrackingArea(tracking)
        trackingArea = tracking

        button.imagePosition = .imageLeading
        button.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self

        updateTitle(MonitorModel.shared.info)
        MonitorModel.shared.addListener { [weak self] info in self?.updateTitle(info) }
    }

    /// Live values next to the icon, chosen in Settings › Menu bar shows.
    private func updateTitle(_ info: SystemInfo) {
        guard let button = statusItem.button else { return }
        let cpu = info.cpuUsage.map { "\(Int($0.rounded()))%" } ?? "—"
        let memory = info.memoryUsage.map { (Double($0) / 1e9).formatted(.number.precision(.fractionLength(1))) + " GB" } ?? "—"
        let network = "↓\(Format.rate(info.downloadRate))"
        let parts: [String] = switch AppSettings.shared.menuBarStyle {
        case .icon: []
        case .cpu: [cpu]
        case .cpuMemory: [cpu, memory]
        case .network: [network]
        case .all: [cpu, memory, network]
        }
        let title = parts.isEmpty ? "" : " " + parts.joined(separator: " · ")
        if button.title != title { button.title = title }
    }

    required init?(coder: NSCoder) { nil }

    // MARK: Hover handling
    override func mouseEntered(with event: NSEvent) {
        hoverTask?.cancel()
        hoverTask = Task { [weak self] in
            // Short delay so sweeping the pointer across the menu bar doesn't open it.
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            self?.showPopover()
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoverTask?.cancel()
    }

    @objc private func togglePopover() {
        hoverTask?.cancel()
        if popover.isShown, pinned {
            close()
        } else {
            pinned = true
            NSApp.activate()
            showPopover()
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: Showing & dismissing
    private func showPopover() {
        guard !popover.isShown, let button = statusItem.button, button.window != nil else { return }
        // Build the content on demand; it is released again in popoverDidClose.
        popover.contentViewController = NSHostingController(rootView: MenuBarView(
            openDashboard: { [weak self] in self?.close(); WindowCoordinator.shared.showDashboard() },
            openTrash: { [weak self] in self?.close(); WindowCoordinator.shared.show(page: .cleanup(.trash)) },
            openNetwork: { [weak self] in self?.close(); WindowCoordinator.shared.show(page: .network) },
            close: { [weak self] in self?.close() }
        ))
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        MonitorModel.shared.setVisible(true, client: "popover")

        // While hovering (not pinned), close once the pointer has left both the icon and the popover.
        dismissalTask?.cancel()
        dismissalTask = Task { [weak self] in
            var outsideChecks = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                guard let self, popover.isShown else { return }
                if pinned || pointerIsInside() {
                    outsideChecks = 0
                } else {
                    outsideChecks += 1
                    // Allow time to cross the small gap between icon and popover.
                    if outsideChecks >= 2 {
                        close()
                        return
                    }
                }
            }
        }
    }

    private func pointerIsInside() -> Bool {
        let pointer = NSEvent.mouseLocation
        if let window = popover.contentViewController?.view.window,
           window.frame.insetBy(dx: -5, dy: -5).contains(pointer) {
            return true
        }
        if let button = statusItem.button, let window = button.window {
            return window.convertToScreen(button.convert(button.bounds, to: nil)).contains(pointer)
        }
        return false
    }

    func close() {
        hoverTask?.cancel()
        dismissalTask?.cancel()
        pinned = false
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        dismissalTask?.cancel()
        pinned = false
        popover.contentViewController = nil
        MonitorModel.shared.setVisible(false, client: "popover")
    }

    func shutdown() {
        close()
        if let trackingArea { statusItem.button?.removeTrackingArea(trackingArea) }
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}

// MARK: - Window management
/// Creates the dashboard and onboarding windows on demand and releases them when
/// closed, so an idle menu-bar app holds no window memory.
@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate {
    static let shared = WindowCoordinator()
    private var dashboard: NSWindow?
    private var onboarding: NSWindow?

    func showDashboard() { show(page: .overview) }

    func show(page: DashboardPage) {
        DashboardNavigation.shared.page = page
        if dashboard == nil {
            dashboard = makeWindow(title: "System Monitor", size: NSSize(width: 1000, height: 800),
                                   resizable: true, content: ContentView())
            dashboard?.minSize = NSSize(width: 900, height: 600)
            MonitorModel.shared.setVisible(true, client: "dashboard")
        }
        present(dashboard)
    }

    func showOnboarding(startAt page: OnboardingPage, verifying: Bool = false) {
        onboarding?.close()
        let view = OnboardingView(startAt: page, verifying: verifying) { [weak self] in self?.onboarding?.close() }
        onboarding = makeWindow(title: "Welcome to System Monitor", size: NSSize(width: 560, height: 500),
                                resizable: false, content: view)
        present(onboarding)
    }

    private func makeWindow<Content: View>(title: String, size: NSSize, resizable: Bool, content: Content) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style,
                              backing: .buffered, defer: false)
        window.title = title
        window.contentViewController = NSHostingController(rootView: content)
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    private func present(_ window: NSWindow?) {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Drops closed windows (and their SwiftUI models) to free memory.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === dashboard {
            window.contentViewController = nil
            dashboard = nil
            MonitorModel.shared.setVisible(false, client: "dashboard")
        } else if window === onboarding {
            onboarding = nil
        }
    }
}
