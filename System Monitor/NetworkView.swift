import SwiftUI
import CoreWLAN
import Observation

// MARK: - Wi-Fi reading
nonisolated struct WiFiReading: Sendable {
    let rssi: Int                    // dBm, e.g. -55
    let noise: Int                   // dBm
    let transmitRate: Double         // Mbps negotiated with the router
    let interface: String
    var quality: ConnectionQuality { ConnectionRatings.signal(rssi: rssi) }

    /// Current Wi-Fi link, or nil when Wi-Fi is off or not connected.
    static func read() -> WiFiReading? {
        guard let interface = CWWiFiClient.shared().interface(), interface.powerOn() else { return nil }
        let rssi = interface.rssiValue()
        guard rssi != 0 else { return nil }
        return WiFiReading(rssi: rssi, noise: interface.noiseMeasurement(),
                           transmitRate: interface.transmitRate(), interface: interface.interfaceName ?? "Wi-Fi")
    }
}

// MARK: - Network model
@MainActor
@Observable
final class NetworkModel {
    enum Phase: Equatable {
        case idle, installing, connecting, testing(SpeedTestEvent.Phase), finished, failed(String)
    }

    var phase: Phase = .idle
    var progress = 0.0
    var liveValue = 0.0              // ms during ping, Mbps during download/upload
    var result: SpeedTestResult?
    var server: String?
    var installLog = ""
    var wifi: WiFiReading?
    var appTraffic: [ProcessTraffic] = []
    var appTrafficError: String?
    var cliInstalled = SpeedTestRunner.cliURL != nil
    @ObservationIgnored private let runner = SpeedTestRunner()
    @ObservationIgnored private var task: Task<Void, Never>?

    var isRunning: Bool {
        switch phase {
        case .installing, .connecting, .testing: true
        default: false
        }
    }

    /// Wi-Fi signal refreshes every 3 seconds while the page is open.
    func monitorWiFi() async {
        while !Task.isCancelled {
            wifi = await Task.detached(priority: .utility) { WiFiReading.read() }.value
            try? await Task.sleep(for: .seconds(3))
        }
    }

    /// Per-app traffic refreshes continuously (each nettop run takes about 2 seconds).
    func monitorAppTraffic() async {
        while !Task.isCancelled {
            do {
                appTraffic = Array(try await NetworkUsageSampler.sample().prefix(8))
                appTrafficError = nil
            } catch is CancellationError {
                return
            } catch {
                appTrafficError = error.localizedDescription
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    // MARK: Speed test
    func installCLI() {
        guard !isRunning else { return }
        phase = .installing
        installLog = "Installing Ookla Speedtest CLI with Homebrew…"
        task = Task {
            do {
                try await runner.install { line in Task { @MainActor in self.installLog = line } }
                cliInstalled = true
                phase = .idle
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func start() {
        guard !isRunning else { return }
        phase = .connecting
        progress = 0
        liveValue = 0
        result = nil
        server = nil
        task = Task {
            do {
                let final = try await runner.run { event in Task { @MainActor in self.handle(event) } }
                result = final
                server = final.server ?? server
                phase = .finished
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        phase = .idle
    }

    /// Live progress only; the final result and errors come from `runner.run`.
    private func handle(_ event: SpeedTestEvent) {
        guard isRunning else { return }               // ignore events that arrive after the end
        switch event {
        case .started(let server, _):
            self.server = server
        case .progress(let stage, let fraction, let value):
            phase = .testing(stage)
            progress = fraction
            liveValue = value
        case .finished, .failed:
            break
        }
    }
}

// MARK: - Network page
struct NetworkView: View {
    @Bindable var model: NetworkModel
    private var monitor = MonitorModel.shared

    init(model: NetworkModel) { self.model = model }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Network", symbol: "network",
                           subtitle: "Live traffic, Wi-Fi signal and a Speedtest.net speed test.")
                liveTraffic
                appTrafficCard
                speedTest
                if let result = model.result { ratings(result) }
            }
            .padding(28)
        }
        .task { await model.monitorWiFi() }
        .task { await model.monitorAppTraffic() }
    }

    // MARK: Per-app traffic
    private var appTrafficCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Apps using the network", systemImage: "app.connected.to.app.below.fill")
                .font(.headline).foregroundStyle(.purple)
            if let error = model.appTrafficError {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if model.appTraffic.isEmpty {
                Text("No app is sending or receiving data right now.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.appTraffic) { process in
                HStack(spacing: 10) {
                    if let path = process.appPath {
                        FileIcon.image(for: path).resizable().frame(width: 20, height: 20)
                    } else {
                        Image(systemName: "gearshape").frame(width: 20, height: 20).foregroundStyle(.secondary)
                    }
                    Text(process.name).lineLimit(1)
                    Spacer()
                    Label(Format.rate(process.download), systemImage: "arrow.down")
                        .frame(width: 110, alignment: .trailing)
                    Label(Format.rate(process.upload), systemImage: "arrow.up")
                        .frame(width: 110, alignment: .trailing)
                }
                .font(.callout.monospacedDigit())
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // MARK: Live traffic & Wi-Fi
    private var liveTraffic: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Download", systemImage: "arrow.down.circle.fill").foregroundStyle(.indigo)
                    Spacer()
                    Text(Format.rate(monitor.info.downloadRate)).font(.title3.weight(.semibold)).monospacedDigit()
                }
                LiveChart(points: monitor.points(for: \.download), color: .indigo,
                          upperBound: monitor.networkUpperBound, latestDate: monitor.latestDate)
                    .frame(height: 50)
                HStack {
                    Label("Upload", systemImage: "arrow.up.circle.fill").foregroundStyle(.teal)
                    Spacer()
                    Text(Format.rate(monitor.info.uploadRate)).font(.title3.weight(.semibold)).monospacedDigit()
                }
                LiveChart(points: monitor.points(for: \.upload), color: .teal,
                          upperBound: monitor.networkUpperBound, latestDate: monitor.latestDate)
                    .frame(height: 50)
            }
            .card()

            VStack(alignment: .leading, spacing: 10) {
                Label("Wi-Fi signal", systemImage: "wifi").font(.headline).foregroundStyle(.purple)
                if let wifi = model.wifi {
                    QualityBadge(quality: wifi.quality)
                    Text("\(wifi.rssi) dBm signal · \(wifi.noise) dBm noise").font(.callout)
                    Text("Link rate \(Int(wifi.transmitRate)) Mbps · \(wifi.interface)")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Not connected to Wi-Fi (wired or offline).").foregroundStyle(.secondary)
                }
            }
            .frame(width: 240, alignment: .leading)
            .card()
        }
    }

    // MARK: Speed test card
    private var speedTest: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Speed test", systemImage: "speedometer").font(.headline).foregroundStyle(.purple)
                Spacer()
                if let server = model.server {
                    Text(server).font(.caption).foregroundStyle(.secondary)
                }
            }

            if !model.cliInstalled {
                // First use: install Ookla's CLI (the only licensed way to use Speedtest.net servers).
                VStack(alignment: .leading, spacing: 8) {
                    Text("Speed tests use Ookla’s official Speedtest CLI and Speedtest.net servers. It’s free for personal use and installs with Homebrew.")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Install Speedtest CLI", systemImage: "arrow.down.circle") { model.installCLI() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isRunning)
                        if model.phase == .installing {
                            ProgressView().controlSize(.small)
                            Text(model.installLog).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            } else {
                HStack(spacing: 28) {
                    gauge
                    VStack(alignment: .leading, spacing: 12) {
                        Text(phaseTitle).font(.title3.weight(.semibold))
                        if model.isRunning {
                            ProgressView(value: model.progress).frame(width: 220)
                            Button("Cancel") { model.cancel() }
                        } else {
                            Button(model.result == nil ? "Start Speed Test" : "Test Again", systemImage: "play.fill") { model.start() }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                        }
                    }
                }
            }

            if case .failed(let message) = model.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled)
            }

            if let result = model.result {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                    StatTile(title: "Ping", value: "\(Int(result.ping.rounded())) ms", symbol: "timer",
                             tint: color(ConnectionRatings.ping(result.ping)))
                    StatTile(title: "Jitter", value: "\(Int(result.jitter.rounded())) ms", symbol: "waveform.path")
                    StatTile(title: "Download", value: "\(Format.megabits(result.download)) Mbps", symbol: "arrow.down")
                    StatTile(title: "Upload", value: "\(Format.megabits(result.upload)) Mbps", symbol: "arrow.up")
                    StatTile(title: "Packet loss",
                             value: result.packetLoss.map { "\($0.formatted(.number.precision(.fractionLength(0...1))))%" } ?? "—",
                             symbol: "shippingbox")
                }
                HStack {
                    if let isp = result.isp { Text("Provider: \(isp)").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    if let url = result.resultURL { Link("View result on Speedtest.net", destination: url).font(.caption) }
                }
            }
        }
        .card()
    }

    /// Circular gauge showing live ping or speed during the test.
    private var gauge: some View {
        let isPing = model.phase == .testing(.ping)
        return ZStack {
            Circle().stroke(Color.secondary.opacity(0.15), lineWidth: 12)
            Circle()
                .trim(from: 0, to: model.isRunning ? model.progress : (model.result == nil ? 0 : 1))
                .stroke(Color.purple, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.2), value: model.progress)
            VStack(spacing: 2) {
                Text(gaugeValue).font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                Text(isPing ? "ms" : "Mbps").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: 140, height: 140)
    }

    private var gaugeValue: String {
        if model.isRunning { return model.liveValue == 0 ? "—" : Format.megabits(model.liveValue) }
        return model.result.map { Format.megabits($0.download) } ?? "—"
    }

    private var phaseTitle: String {
        switch model.phase {
        case .idle: model.result == nil ? "Ready to test" : "Last result"
        case .installing: "Installing…"
        case .connecting: "Finding the best server…"
        case .testing(.ping): "Testing ping…"
        case .testing(.download): "Testing download…"
        case .testing(.upload): "Testing upload…"
        case .finished: "Test complete"
        case .failed: "Test failed"
        }
    }

    // MARK: Ratings
    /// Speedtest-style verdicts: what this connection is good for.
    private func ratings(_ result: SpeedTestResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("What your connection is good for", systemImage: "checkmark.seal").font(.headline).foregroundStyle(.purple)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                ForEach(ConnectionRatings.ratings(for: result)) { rating in
                    HStack(spacing: 12) {
                        Image(systemName: rating.symbol)
                            .font(.title2)
                            .foregroundStyle(color(rating.quality))
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(rating.activity).font(.subheadline.weight(.semibold))
                            QualityBadge(quality: rating.quality)
                            Text(rating.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .card(padding: 12)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func color(_ quality: ConnectionQuality) -> Color { QualityBadge.color(quality) }
}

// MARK: - Quality badge
struct QualityBadge: View {
    let quality: ConnectionQuality

    var body: some View {
        Text(quality.label)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .foregroundStyle(Self.color(quality))
            .background(Self.color(quality).opacity(0.14), in: Capsule())
    }

    static func color(_ quality: ConnectionQuality) -> Color {
        switch quality {
        case .excellent: .green
        case .good: .teal
        case .fair: .orange
        case .poor: .red
        }
    }
}
