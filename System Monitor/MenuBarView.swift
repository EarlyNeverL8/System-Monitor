import SwiftUI

// MARK: - Menu bar popover
/// Compact live readings: CPU (with chip details), memory, storage and network.
struct MenuBarView: View {
    private var monitor = MonitorModel.shared
    @Environment(\.openSettings) private var openSettings
    let openDashboard: () -> Void
    let openTrash: () -> Void
    let openNetwork: () -> Void
    let close: () -> Void

    init(openDashboard: @escaping () -> Void, openTrash: @escaping () -> Void,
         openNetwork: @escaping () -> Void, close: @escaping () -> Void) {
        self.openDashboard = openDashboard
        self.openTrash = openTrash
        self.openNetwork = openNetwork
        self.close = close
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with close button.
            HStack {
                Image(systemName: "sparkles").foregroundStyle(.purple)
                Text("System Monitor").font(.headline)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close")
                .accessibilityLabel("Close readings")
            }
            .padding(.bottom, 14)

            // CPU: chip name and core counts under the heading.
            metric(title: "CPU", symbol: "cpu", color: .blue,
                   value: Format.percent(monitor.info.cpuUsage),
                   subtitle: "\(monitor.hardware.chipName) · \(monitor.hardware.coreSummary)",
                   points: monitor.points(for: \.cpuUsage), upperBound: 100)
            Divider().padding(.vertical, 10)

            metric(title: "Memory", symbol: "memorychip", color: .purple,
                   value: Format.bytes(monitor.info.memoryUsage),
                   subtitle: "of \(Format.bytes(monitor.info.memoryTotal))",
                   points: monitor.points(for: \.memoryUsage),
                   upperBound: max(Double(monitor.info.memoryTotal) / 1e9, 1))
            Divider().padding(.vertical, 10)

            // Storage: "260 GB of 500 GB available".
            metric(title: "Storage", symbol: "internaldrive", color: .teal,
                   value: Format.storage(monitor.info.diskSpaceAvailable),
                   subtitle: Format.storageSummary(available: monitor.info.diskSpaceAvailable,
                                                   total: monitor.info.diskSpaceTotal),
                   points: monitor.points(for: \.diskSpaceAvailable),
                   upperBound: monitor.diskUpperBound)
            actionRow("Trash & applications", button: "Clean Up", action: openTrash)
            Divider().padding(.vertical, 10)

            // Network: live download / upload.
            HStack {
                Label("Network", systemImage: "network")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.indigo)
                Spacer()
                Label(Format.rate(monitor.info.downloadRate), systemImage: "arrow.down")
                Label(Format.rate(monitor.info.uploadRate), systemImage: "arrow.up")
            }
            .font(.caption.monospacedDigit())
            actionRow("Test your connection", button: "Speed Test", action: openNetwork)

            Divider().padding(.vertical, 12)
            HStack {
                Button("Open Dashboard", action: openDashboard)
                    .buttonStyle(.plain)
                    .foregroundStyle(.purple)
                Spacer()
                Button {
                    close()
                    NSApp.activate()
                    openSettings()
                } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.plain)
                    .help("Settings")
                    .accessibilityLabel("Settings")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(.plain)
                    .help("Quit System Monitor")
                    .accessibilityLabel("Quit System Monitor")
            }
            .font(.caption.weight(.medium))
        }
        .padding(16)
        .frame(width: 340)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(.purple)
    }

    private func actionRow(_ title: String, button: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Button(button, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .font(.caption)
        .padding(.top, 5)
    }

    private func metric(title: String, symbol: String, color: Color, value: String,
                        subtitle: String, points: [MetricPoint], upperBound: Double) -> some View {
        VStack(spacing: 5) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(color)
                Spacer()
                Text(value).font(.headline).monospacedDigit()
            }
            HStack {
                Text(subtitle).lineLimit(1)
                Spacer()
                Text("60s")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            LiveChart(points: points, color: color, upperBound: upperBound, latestDate: monitor.latestDate)
                .frame(height: 34)
        }
        // `.contain` keeps the title, value and subtitle individually addressable
        // (e.g. by UI tests) while still grouping them for VoiceOver navigation.
        .accessibilityElement(children: .contain)
    }
}

#Preview("Compact Menu") {
    MenuBarView(openDashboard: {}, openTrash: {}, openNetwork: {}, close: {})
}
