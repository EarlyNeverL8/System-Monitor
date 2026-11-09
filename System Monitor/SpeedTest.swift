import Foundation

// MARK: - Speed test results
/// Final numbers from a Speedtest.net run (speeds in megabits per second).
nonisolated struct SpeedTestResult: Sendable, Equatable {
    var ping: Double                 // ms
    var jitter: Double               // ms
    var download: Double             // Mbps
    var upload: Double               // Mbps
    var packetLoss: Double?          // percent
    var isp: String?
    var server: String?
    var resultURL: URL?
}

/// One line of progress from the Ookla CLI's JSON-lines output.
nonisolated enum SpeedTestEvent: Sendable, Equatable {
    enum Phase: String, Sendable { case ping, download, upload }
    case started(server: String?, isp: String?)
    case progress(Phase, fraction: Double, value: Double)     // value: ms for ping, Mbps otherwise
    case finished(SpeedTestResult)
    case failed(String)
}

// MARK: - Ookla CLI output parser
nonisolated enum SpeedTestParser {
    /// Parses one `speedtest --format=jsonl` line. Bandwidth is reported in bytes/s.
    static func parse(_ line: String) -> SpeedTestEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        func megabits(_ section: String) -> Double {
            ((object[section] as? [String: Any])?["bandwidth"] as? Double ?? 0) * 8 / 1_000_000
        }
        func fraction(_ section: String) -> Double {
            (object[section] as? [String: Any])?["progress"] as? Double ?? 0
        }
        let ping = object["ping"] as? [String: Any]
        switch type {
        case "testStart":
            return .started(server: serverName(object), isp: object["isp"] as? String)
        case "ping":
            return .progress(.ping, fraction: fraction("ping"), value: ping?["latency"] as? Double ?? 0)
        case "download":
            return .progress(.download, fraction: fraction("download"), value: megabits("download"))
        case "upload":
            return .progress(.upload, fraction: fraction("upload"), value: megabits("upload"))
        case "result":
            let link = (object["result"] as? [String: Any])?["url"] as? String
            return .finished(SpeedTestResult(
                ping: ping?["latency"] as? Double ?? 0,
                jitter: ping?["jitter"] as? Double ?? 0,
                download: megabits("download"),
                upload: megabits("upload"),
                packetLoss: object["packetLoss"] as? Double,
                isp: object["isp"] as? String,
                server: serverName(object),
                resultURL: link.flatMap(URL.init(string:))))
        case "log" where (object["level"] as? String) == "error":
            return .failed(object["message"] as? String ?? "The speed test failed.")
        default:
            return nil
        }
    }

    private static func serverName(_ object: [String: Any]) -> String? {
        guard let server = object["server"] as? [String: Any], let name = server["name"] as? String else { return nil }
        return [name, server["location"] as? String].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - Connection quality ratings
nonisolated enum ConnectionQuality: Int, Comparable, Sendable {
    case poor, fair, good, excellent
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .poor: "Poor"
        case .fair: "Fair"
        case .good: "Good"
        case .excellent: "Excellent"
        }
    }
}

/// How well the connection suits an activity, like Speedtest's post-test summary.
nonisolated struct UsageRating: Identifiable, Sendable {
    let activity: String
    let symbol: String
    let quality: ConnectionQuality
    let detail: String
    var id: String { activity }
}

nonisolated enum ConnectionRatings {
    static func ratings(for result: SpeedTestResult) -> [UsageRating] {
        let loss = result.packetLoss ?? 0
        let (down, up, ping, jitter) = (result.download, result.upload, result.ping, result.jitter)

        // Gaming depends mostly on latency, jitter and packet loss.
        let gaming: ConnectionQuality =
            ping <= 20 && jitter <= 5 && loss <= 0.5 && down >= 15 ? .excellent :
            ping <= 50 && jitter <= 15 && loss <= 1 && down >= 5 ? .good :
            ping <= 100 && jitter <= 30 && loss <= 2.5 ? .fair : .poor

        // Streaming depends on sustained download speed.
        let streaming: ConnectionQuality = down >= 25 ? .excellent : down >= 10 ? .good : down >= 5 ? .fair : .poor
        let streamingDetail = down >= 25 ? "4K Ultra HD" : down >= 10 ? "Full HD 1080p" : down >= 5 ? "HD 720p" : "Standard definition"

        // Video calls need upload speed and steady latency in both directions.
        let calls: ConnectionQuality =
            up >= 3 && down >= 4 && ping <= 50 && jitter <= 20 ? .excellent :
            up >= 1.5 && down >= 2.5 && ping <= 100 ? .good :
            up >= 0.6 && ping <= 150 ? .fair : .poor

        let browsing: ConnectionQuality =
            down >= 25 && ping <= 60 ? .excellent : down >= 10 && ping <= 100 ? .good : down >= 3 ? .fair : .poor

        // Large downloads/uploads (game installs, cloud backups) are bandwidth-bound.
        let transfers: ConnectionQuality = min(down / 4, up) >= 50 ? .excellent : min(down / 4, up) >= 10 ? .good
            : min(down / 4, up) >= 2 ? .fair : .poor

        return [
            UsageRating(activity: "Online gaming", symbol: "gamecontroller.fill", quality: gaming,
                        detail: "\(Int(ping.rounded())) ms ping, \(Int(jitter.rounded())) ms jitter"),
            UsageRating(activity: "Video streaming", symbol: "play.tv.fill", quality: streaming, detail: streamingDetail),
            UsageRating(activity: "Video calls", symbol: "video.fill", quality: calls,
                        detail: "\(Format.megabits(up)) Mbps upload"),
            UsageRating(activity: "Web browsing", symbol: "safari.fill", quality: browsing,
                        detail: "\(Format.megabits(down)) Mbps download"),
            UsageRating(activity: "Downloads & backups", symbol: "icloud.and.arrow.up.fill", quality: transfers,
                        detail: "Large file transfers")
        ]
    }

    static func ping(_ milliseconds: Double) -> ConnectionQuality {
        milliseconds <= 20 ? .excellent : milliseconds <= 50 ? .good : milliseconds <= 100 ? .fair : .poor
    }

    /// Wi-Fi signal strength (RSSI in dBm).
    static func signal(rssi: Int) -> ConnectionQuality {
        rssi >= -50 ? .excellent : rssi >= -60 ? .good : rssi >= -70 ? .fair : .poor
    }
}

// MARK: - Speed test runner
/// Runs Ookla's official Speedtest CLI, which uses Speedtest.net servers.
actor SpeedTestRunner {
    static var cliURL: URL? { Shell.tool("speedtest") }

    /// Installs the CLI from Ookla's Homebrew tap.
    func install(progress: @escaping @Sendable (String) -> Void) async throws {
        guard let brew = Shell.brew else {
            throw Shell.Failure("Homebrew isn’t installed. Install it from brew.sh, then try again.")
        }
        let result = try await Shell.run(brew, ["install", "teamookla/speedtest/speedtest"], onLine: progress)
        guard result.succeeded, Self.cliURL != nil else {
            throw Shell.Failure("Couldn’t install the Speedtest CLI: \(result.message)")
        }
    }

    /// Runs one test, reporting progress events as they arrive, and returns the final result.
    func run(onEvent: @escaping @Sendable (SpeedTestEvent) -> Void) async throws -> SpeedTestResult {
        guard let cli = Self.cliURL else { throw Shell.Failure("The Speedtest CLI isn’t installed.") }
        // A different tool (e.g. the Python speedtest-cli) can also be called "speedtest".
        let version = try await Shell.run(cli, ["--version"])
        guard version.stdout.contains("Ookla") else {
            throw Shell.Failure("The installed “speedtest” command isn’t Ookla’s. Run “brew uninstall speedtest-cli”, then install again.")
        }
        let output = try await Shell.run(
            cli, ["--accept-license", "--accept-gdpr", "--format=jsonl", "--progress=yes"],
            onLine: { line in if let event = SpeedTestParser.parse(line) { onEvent(event) } })
        // Errors and the result are JSON lines too; re-read the complete output.
        let events = (output.stdout + "\n" + output.stderr).split(separator: "\n").compactMap { SpeedTestParser.parse(String($0)) }
        if let result = events.lazy.compactMap({ if case .finished(let result) = $0 { result } else { nil } }).last {
            return result
        }
        let reason = events.compactMap { if case .failed(let message) = $0 { message } else { nil } }.first
        throw Shell.Failure(reason ?? (output.message.isEmpty ? "The test ended without a result." : output.message))
    }
}
