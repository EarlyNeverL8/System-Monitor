import SwiftUI
import Charts
import IOKit
import IOKit.ps
import Observation

// MARK: - Battery reading
/// Battery health and charge details from the AppleSmartBattery IOKit service.
nonisolated struct BatteryInfo: Sendable, Equatable {
    var chargePercent: Int
    var healthPercent: Int?                 // maximum capacity vs. design capacity
    var condition: String                   // "Normal" or "Service Recommended"
    var cycleCount: Int?
    var designCycleCount: Int?
    var fullChargeCapacity: Int?            // mAh the battery holds today
    var designCapacity: Int?                // mAh when new
    var isCharging: Bool
    var isPluggedIn: Bool
    var isFullyCharged: Bool
    var minutesRemaining: Int?
    var voltage: Double?                    // volts
    var amperage: Double?                   // amps; negative while discharging
    var temperature: Double?                // °C
    var adapterWatts: Int?

    var powerWatts: Double? {
        guard let voltage, let amperage else { return nil }
        return abs(voltage * amperage)
    }

    /// Reads the current battery state, or nil on Macs without a battery.
    static func read() -> BatteryInfo? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = unmanaged?.takeRetainedValue() as? [String: Any],
              properties["BatteryInstalled"] as? Bool != false else { return nil }
        return make(from: properties, powerSourceHealth: powerSourceHealth())
    }

    /// Builds the reading from raw IOKit properties (separate so tests can feed fixtures).
    static func make(from properties: [String: Any], powerSourceHealth: String?) -> BatteryInfo {
        // Newer Macs keep the mAh values inside "BatteryData"; older ones at the top level.
        let data = properties["BatteryData"] as? [String: Any] ?? [:]
        func int(_ key: String) -> Int? { (data[key] as? Int) ?? (properties[key] as? Int) }

        let design = int("DesignCapacity").flatMap { $0 > 0 ? $0 : nil }
        let nominal = int("NominalChargeCapacity") ?? int("AppleRawMaxCapacity")
        let health = design.flatMap { design in nominal.map { min(100, Int((Double($0) / Double(design) * 100).rounded())) } }

        // Current/MaxCapacity are percentages on Apple silicon; compute defensively.
        let current = properties["CurrentCapacity"] as? Int ?? 0
        let maximum = max(properties["MaxCapacity"] as? Int ?? 100, 1)
        let minutes = (properties["TimeRemaining"] as? Int).flatMap { $0 > 0 && $0 < 65535 ? $0 : nil }
        let adapter = properties["AdapterDetails"] as? [String: Any]

        // A non-empty BatteryHealthCondition (e.g. "Check Battery") overrides "Good".
        let flagged = (properties["BatteryHealthCondition"] as? String).map { !$0.isEmpty } ?? false
        let condition = flagged || (powerSourceHealth.map { $0 != "Good" } ?? false)
            ? "Service Recommended" : "Normal"

        return BatteryInfo(
            chargePercent: min(100, current * 100 / maximum),
            healthPercent: health,
            condition: condition,
            cycleCount: properties["CycleCount"] as? Int,
            designCycleCount: properties["DesignCycleCount9C"] as? Int,
            fullChargeCapacity: nominal,
            designCapacity: design,
            isCharging: properties["IsCharging"] as? Bool ?? false,
            isPluggedIn: properties["ExternalConnected"] as? Bool ?? false,
            isFullyCharged: properties["FullyCharged"] as? Bool ?? false,
            minutesRemaining: minutes,
            voltage: (properties["Voltage"] as? Int).map { Double($0) / 1000 },
            amperage: (properties["Amperage"] as? Int).map { Double($0) / 1000 },
            temperature: ((properties["Temperature"] as? Int) ?? (properties["VirtualTemperature"] as? Int))
                .map { Double($0) / 100 },
            adapterWatts: adapter?["Watts"] as? Int
        )
    }

    /// macOS's own health verdict ("Good", "Fair", "Poor") from the power-source API.
    private static func powerSourceHealth() -> String? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            if let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
               let health = description["BatteryHealth"] as? String {
                return health
            }
        }
        return nil
    }
}

// MARK: - Battery model
@MainActor
@Observable
final class BatteryModel {
    private(set) var info: BatteryInfo?
    private(set) var loaded = false
    private(set) var history: [BatterySnapshot] = []

    /// Refreshes every 5 seconds while the Battery page is open.
    func monitor() async {
        while !Task.isCancelled {
            info = await Task.detached(priority: .utility) { BatteryInfo.read() }.value
            if !loaded, let info {
                BatteryHistory.record(info)
                history = BatteryHistory.load()
            }
            loaded = true
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
        }
    }
}

// MARK: - Battery page
struct BatteryView: View {
    @State private var model = BatteryModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Battery", symbol: "battery.100percent",
                           subtitle: "Health, capacity and charging details for your Mac’s battery.")
                if let info = model.info {
                    content(info)
                } else if model.loaded {
                    ContentUnavailableView("No battery", systemImage: "powerplug",
                                           description: Text("This Mac runs on mains power only."))
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 300)
                }
            }
            .padding(28)
        }
        .task { await model.monitor() }
    }

    @ViewBuilder
    private func content(_ info: BatteryInfo) -> some View {
        // Health ring + headline numbers.
        HStack(spacing: 28) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.15), lineWidth: 14)
                Circle()
                    .trim(from: 0, to: Double(info.healthPercent ?? 0) / 100)
                    .stroke(healthColor(info), style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 2) {
                    Text(info.healthPercent.map { "\($0)%" } ?? "—")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("Max capacity").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 150, height: 150)
            .accessibilityElement(children: .combine)

            VStack(alignment: .leading, spacing: 10) {
                Label("Battery health: \(info.condition)",
                      systemImage: info.condition == "Normal" ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(info.condition == "Normal" ? .green : .orange)
                Text(healthExplanation(info)).foregroundStyle(.secondary)
                Label(chargeText(info), systemImage: info.isPluggedIn ? "bolt.fill" : "battery.75percent")
                    .font(.headline)
            }
        }
        .card()

        // Detail tiles.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
            StatTile(title: "Charge", value: "\(info.chargePercent)%", symbol: "battery.100percent.bolt")
            StatTile(title: "Cycle count",
                     value: info.cycleCount.map { count in info.designCycleCount.map { "\(count) of \($0)" } ?? "\(count)" } ?? "—",
                     symbol: "arrow.triangle.2.circlepath")
            StatTile(title: "Full charge capacity", value: info.fullChargeCapacity.map { "\($0) mAh" } ?? "—",
                     symbol: "gauge.with.dots.needle.67percent")
            StatTile(title: "Design capacity", value: info.designCapacity.map { "\($0) mAh" } ?? "—",
                     symbol: "gauge.with.dots.needle.100percent")
            StatTile(title: info.isPluggedIn ? "Power in" : "Power draw",
                     value: info.powerWatts.map { $0.formatted(.number.precision(.fractionLength(1))) + " W" } ?? "—",
                     symbol: "bolt")
            StatTile(title: "Voltage", value: info.voltage.map { $0.formatted(.number.precision(.fractionLength(2))) + " V" } ?? "—",
                     symbol: "waveform.path.ecg")
            if let temperature = info.temperature {
                StatTile(title: "Temperature", value: temperature.formatted(.number.precision(.fractionLength(1))) + " °C",
                         symbol: "thermometer.medium")
            }
            if let watts = info.adapterWatts, info.isPluggedIn {
                StatTile(title: "Power adapter", value: "\(watts) W", symbol: "powerplug")
            }
        }

        healthHistory
    }

    /// Maximum capacity over time, one reading per day while System Monitor runs.
    private var healthHistory: some View {
        let readings = model.history.filter { $0.healthPercent != nil }
        return VStack(alignment: .leading, spacing: 10) {
            Label("Health history", systemImage: "chart.line.downtrend.xyaxis")
                .font(.headline).foregroundStyle(.purple)
            if readings.count < 2 {
                Text("System Monitor records your battery’s health once a day. A trend appears after a few days.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Chart(readings) { reading in
                    LineMark(x: .value("Date", reading.date, unit: .day),
                             y: .value("Health", reading.healthPercent ?? 0))
                        .foregroundStyle(.green)
                    PointMark(x: .value("Date", reading.date, unit: .day),
                              y: .value("Health", reading.healthPercent ?? 0))
                        .foregroundStyle(.green)
                }
                .chartYScale(domain: max(0, (readings.compactMap(\.healthPercent).min() ?? 80) - 5)...100)
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%") }
                    }
                }
                .frame(height: 140)
                if let first = readings.first, let last = readings.last,
                   let firstCycles = first.cycleCount, let lastCycles = last.cycleCount {
                    Text("\(lastCycles - firstCycles) charge cycles since \(first.date.formatted(date: .abbreviated, time: .omitted)).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func healthColor(_ info: BatteryInfo) -> Color {
        switch info.healthPercent ?? 0 {
        case 80...: .green
        case 60..<80: .orange
        default: .red
        }
    }

    private func healthExplanation(_ info: BatteryInfo) -> String {
        guard let health = info.healthPercent else { return "Capacity data isn’t available for this battery." }
        return health >= 80
            ? "Your battery holds \(health)% of its original charge. Batteries are designed to keep 80% at \(info.designCycleCount ?? 1000) cycles."
            : "Your battery holds \(health)% of its original charge. Consider a battery service if run time no longer meets your needs."
    }

    private func chargeText(_ info: BatteryInfo) -> String {
        if info.isFullyCharged { return "\(info.chargePercent)% · Fully charged" }
        if info.isCharging { return "\(info.chargePercent)% · Charging" }
        if info.isPluggedIn { return "\(info.chargePercent)% · Plugged in, not charging" }
        guard let minutes = info.minutesRemaining else { return "\(info.chargePercent)% · On battery" }
        return "\(info.chargePercent)% · \(minutes / 60) h \(minutes % 60) min remaining"
    }
}
