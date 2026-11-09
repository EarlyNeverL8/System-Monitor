import SwiftUI

// MARK: - Overview page
/// Live CPU, memory, storage and network cards with 60-second charts,
/// laid out in a 2×2 grid that fills the window so nothing needs scrolling.
struct OverviewView: View {
    private var monitor = MonitorModel.shared
    @AppStorage("overviewRange") private var range: HistoryRange = .minute

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Your Mac, at a glance").font(.largeTitle.bold())
                    Text("Live performance. A little more breathing room.").foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Chart range", selection: $range) {
                    ForEach(HistoryRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Label("Live", systemImage: "waveform.path")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }

            statStrip

            Grid(horizontalSpacing: 18, verticalSpacing: 18) {
                GridRow {
                    // CPU: chip name, CPU and GPU core counts.
                    MetricCard(
                        title: "CPU Usage", symbol: "cpu", color: .blue,
                        reading: Format.percent(monitor.info.cpuUsage),
                        detail: "\(monitor.hardware.chipName) · \(monitor.hardware.coreSummary)",
                        unit: "%", upperBound: 100,
                        points: monitor.points(for: \.cpuUsage, range: range), latestDate: monitor.latestDate, range: range
                    )

                    MetricCard(
                        title: "Memory", symbol: "memorychip", color: .purple,
                        reading: Format.bytes(monitor.info.memoryUsage),
                        detail: "of \(Format.bytes(monitor.info.memoryTotal)) physical memory",
                        unit: " GB", upperBound: max(Double(monitor.info.memoryTotal) / 1e9, 1),
                        points: monitor.points(for: \.memoryUsage, range: range), latestDate: monitor.latestDate, range: range
                    )
                }

                GridRow {
                    // Storage: "260 GB of 500 GB available" + shortcut to Trash cleanup.
                    VStack(spacing: 10) {
                        MetricCard(
                            title: "Storage", symbol: "internaldrive", color: .teal,
                            reading: Format.storage(monitor.info.diskSpaceAvailable),
                            detail: Format.storageSummary(available: monitor.info.diskSpaceAvailable,
                                                          total: monitor.info.diskSpaceTotal),
                            unit: " GB", upperBound: monitor.diskUpperBound,
                            points: monitor.points(for: \.diskSpaceAvailable, range: range), latestDate: monitor.latestDate, range: range
                        )
                        shortcut("Trash, browsers & applications", symbol: "sparkles", button: "Clean Up") {
                            DashboardNavigation.shared.page = .cleanup(.trash)
                        }
                    }

                    VStack(spacing: 10) {
                        MetricCard(
                            title: "Network", symbol: "network", color: .indigo,
                            reading: "↓ \(Format.rate(monitor.info.downloadRate))",
                            detail: "↑ \(Format.rate(monitor.info.uploadRate)) upload",
                            unit: " MB/s", upperBound: monitor.networkUpperBound(for: range),
                            points: monitor.points(for: \.download, range: range), latestDate: monitor.latestDate, range: range
                        )
                        shortcut("Check ping, download and upload speed", symbol: "speedometer", button: "Speed Test") {
                            DashboardNavigation.shared.page = .network
                        }
                    }
                }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// GPU, memory pressure, swap and disk activity at a glance.
    private var statStrip: some View {
        HStack(spacing: 12) {
            StatTile(title: "GPU", value: Format.percent(monitor.info.gpuUsage), symbol: "cpu.fill", tint: .orange)
            StatTile(title: "Memory pressure", value: monitor.info.memoryPressure?.label ?? "—",
                     symbol: "gauge.with.dots.needle.33percent", tint: pressureColor)
            StatTile(title: "Swap used", value: Format.bytes(monitor.info.swapUsed), symbol: "arrow.left.arrow.right")
            StatTile(title: "Disk read · write",
                     value: "\(Format.rate(monitor.info.diskReadRate)) · \(Format.rate(monitor.info.diskWriteRate))",
                     symbol: "internaldrive")
        }
    }

    private var pressureColor: Color {
        switch monitor.info.memoryPressure {
        case .warning: .orange
        case .critical: .red
        default: .green
        }
    }

    private func shortcut(_ detail: String, symbol: String, button: String, action: @escaping () -> Void) -> some View {
        HStack {
            Label(detail, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(button, action: action)
                .buttonStyle(.borderedProminent)
                .accessibilityHint(detail)
        }
        .padding(.horizontal, 8)
    }
}

// MARK: - Metric card
/// Heading, current reading, detail line and a live 60-second chart.
struct MetricCard: View {
    let title: String
    let symbol: String
    let color: Color
    let reading: String
    let detail: String
    let unit: String
    let upperBound: Double
    let points: [MetricPoint]
    let latestDate: Date
    var range: HistoryRange = .minute

    /// Minimum chart height; the chart grows to fill the card's share of the window.
    @ScaledMetric private var graphHeight: CGFloat = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(title, systemImage: symbol)
                        .font(.headline)
                        .foregroundStyle(color)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Text(reading)
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
            }

            LiveChart(points: points, color: color, upperBound: upperBound, latestDate: latestDate,
                      unit: unit == "%" ? "%" : "", showsAxis: true, span: range.seconds)
                .frame(minHeight: graphHeight, maxHeight: .infinity)
                .overlay {
                    if points.isEmpty {
                        Text(range == .minute ? "Collecting readings…" : "History builds up while System Monitor runs.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

            HStack {
                Text(range.startLabel)
                Spacer()
                Text(unit == "%" ? "Now" : "\(unit.trimmingCharacters(in: .whitespaces)) · Now")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .card()
        .accessibilityElement(children: .combine)
    }
}

#Preview("Dashboard") {
    ContentView().frame(width: 1000, height: 800)
}
