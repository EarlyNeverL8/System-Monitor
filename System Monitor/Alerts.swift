import Foundation
import UserNotifications

// MARK: - Alerts
/// Watches each reading and posts a notification when a threshold from Settings
/// is crossed. Each kind of alert is sent at most once an hour.
@MainActor
final class AlertCenter {
    static let shared = AlertCenter()

    enum Kind: String {
        case highCPU, lowDisk, memoryPressure, batteryHealth
    }

    private let settings = AppSettings.shared
    private var highCPUSince: Date?
    private var lastSent: [Kind: Date] = [:]
    private var lastBatteryCheck: Date?

    func start() {
        MonitorModel.shared.addListener { [weak self] info in self?.evaluate(info) }
    }

    func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    private func evaluate(_ info: SystemInfo) {
        let now = Date()
        // Battery: record health once a day (for the history chart) and check it hourly.
        if lastBatteryCheck.map({ now.timeIntervalSince($0) > 3_600 }) ?? true {
            lastBatteryCheck = now
            Task {
                guard let battery = await Task.detached(priority: .utility, operation: { BatteryInfo.read() }).value else { return }
                BatteryHistory.record(battery)
                if let health = battery.healthPercent, health < 80, settings.alertsEnabled, settings.batteryHealthAlert {
                    send(.batteryHealth, title: "Battery health is \(health)%",
                         body: "Your battery holds less than 80% of its original charge. Consider a battery service.")
                }
            }
        }

        guard settings.alertsEnabled else { return }

        if let cpu = info.cpuUsage, settings.highCPUAlert, cpu >= settings.highCPUThreshold {
            let since = highCPUSince ?? now
            highCPUSince = since
            if now.timeIntervalSince(since) >= 120 {
                send(.highCPU, title: "CPU has been busy for 2 minutes",
                     body: "CPU usage is \(Format.percent(cpu)). Open Performance › Heavy Consumers to see which apps are responsible.")
            }
        } else {
            highCPUSince = nil
        }

        if let available = info.diskSpaceAvailable, settings.lowDiskAlert,
           Double(available) / 1e9 < settings.lowDiskGigabytes {
            send(.lowDisk, title: "Your startup disk is almost full",
                 body: "\(Format.storage(available)) available. System Junk and Storage can help free up space.")
        }

        if info.memoryPressure == .critical, settings.memoryPressureAlert {
            send(.memoryPressure, title: "Memory pressure is critical",
                 body: "Your Mac is short of memory and may slow down. Quit apps you aren’t using.")
        }
    }

    private func send(_ kind: Kind, title: String, body: String) {
        if let last = lastSent[kind], Date().timeIntervalSince(last) < 3_600 { return }
        lastSent[kind] = Date()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: kind.rawValue, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - Battery history
/// One daily snapshot of battery health, kept so the Battery page can chart wear over time.
nonisolated struct BatterySnapshot: Codable, Sendable, Identifiable {
    let date: Date
    let healthPercent: Int?
    let cycleCount: Int?
    let fullChargeCapacity: Int?
    var id: Date { date }
}

nonisolated enum BatteryHistory {
    static var url: URL { AppSupport.folder.appendingPathComponent("battery-history.json") }

    static func load() -> [BatterySnapshot] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([BatterySnapshot].self, from: data)) ?? []
    }

    /// Adds today's reading, replacing an earlier reading from the same day.
    static func record(_ battery: BatteryInfo, on date: Date = Date()) {
        var snapshots = load()
        snapshots.removeAll { Calendar.current.isDate($0.date, inSameDayAs: date) }
        snapshots.append(BatterySnapshot(date: date, healthPercent: battery.healthPercent,
                                         cycleCount: battery.cycleCount, fullChargeCapacity: battery.fullChargeCapacity))
        snapshots.sort { $0.date < $1.date }
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
