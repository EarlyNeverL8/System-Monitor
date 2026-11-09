import Foundation
import Observation

// MARK: - Chart ranges
/// How far back the dashboard charts look. The last minute uses raw samples;
/// longer ranges use per-minute averages kept for a week.
enum HistoryRange: String, CaseIterable, Identifiable {
    case minute = "1 min"
    case hour = "1 hour"
    case day = "24 hours"
    case week = "7 days"

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .minute: 60
        case .hour: 3_600
        case .day: 86_400
        case .week: 604_800
        }
    }

    /// Caption under each chart: "60 seconds ago … Now".
    var startLabel: String {
        switch self {
        case .minute: "60 seconds ago"
        case .hour: "1 hour ago"
        case .day: "24 hours ago"
        case .week: "7 days ago"
        }
    }
}

// MARK: - Monitor model
/// Shared live readings for the menu bar and dashboard. Samples every second while
/// something is on screen; otherwise every 2 seconds when the menu bar shows live
/// values, or every 5 seconds to save energy.
@MainActor
@Observable
final class MonitorModel {
    static let shared = MonitorModel()

    private(set) var info = SystemInfo()
    private(set) var history: [ReadingSample] = []
    /// Per-minute averages for the last 7 days.
    private(set) var minuteHistory: [ReadingSample] = []
    private(set) var latestDate = Date()
    let hardware = HardwareInfo.current

    @ObservationIgnored private let sampler = SystemSampler()
    @ObservationIgnored private var samplingTask: Task<Void, Never>?
    @ObservationIgnored private var visibleClients: Set<String> = []
    @ObservationIgnored private var listeners: [@MainActor (SystemInfo) -> Void] = []
    @ObservationIgnored private var minute = MinuteAccumulator()
    @ObservationIgnored private var unsavedMinutes = 0
    // Chart points are derived once per sample (or per minute for long ranges)
    // instead of on every view redraw.
    @ObservationIgnored private var pointCache: [KeyPath<ReadingSample, Double?>: [MetricPoint]] = [:]
    @ObservationIgnored private var longPointCache: [String: [MetricPoint]] = [:]

    // MARK: Sampling loop
    func start() {
        guard samplingTask == nil else { return }
        if minuteHistory.isEmpty { minuteHistory = HistoryStore.load() }
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let reading = await self?.sampler.sample(), let self else { return }
                record(reading)
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }

    func stop() {
        samplingTask?.cancel()
        samplingTask = nil
    }

    /// Writes the per-minute history to disk (called at quit).
    func saveHistory() {
        HistoryStore.save(minuteHistory)
        unsavedMinutes = 0
    }

    func clearHistory() {
        minuteHistory = []
        longPointCache.removeAll()
        HistoryStore.clear()
    }

    private var interval: Duration {
        if !visibleClients.isEmpty { return .seconds(1) }
        return AppSettings.shared.menuBarStyle == .icon ? .seconds(5) : .seconds(2)
    }

    /// Windows and the popover register while visible so sampling speeds up; the
    /// loop restarts immediately so a newly opened view gets a fresh reading.
    func setVisible(_ visible: Bool, client: String) {
        let wasIdle = visibleClients.isEmpty
        if visible { visibleClients.insert(client) } else { visibleClients.remove(client) }
        if wasIdle, visible, samplingTask != nil {
            stop()
            start()
        }
    }

    /// Called with every new reading (menu bar text, alerts).
    func addListener(_ listener: @escaping @MainActor (SystemInfo) -> Void) {
        listeners.append(listener)
    }

    private func record(_ reading: SystemInfo) {
        let date = Date()
        info = reading
        latestDate = date
        let sample = ReadingSample(date: date, info: reading)
        history.append(sample)
        // Keep only the 60-second window the live charts display.
        history.removeAll { $0.date < date.addingTimeInterval(-60) || $0.date > date }
        pointCache.removeAll(keepingCapacity: true)
        accumulate(sample)
        listeners.forEach { $0(reading) }
    }

    /// Averages samples into one entry per minute for the long-range charts.
    private func accumulate(_ sample: ReadingSample) {
        let start = Date(timeIntervalSinceReferenceDate: (sample.date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
        if let current = minute.start, current != start, let average = minute.average() {
            minuteHistory.append(average)
            let cutoff = sample.date.addingTimeInterval(-HistoryRange.week.seconds)
            if let first = minuteHistory.first, first.date < cutoff { minuteHistory.removeAll { $0.date < cutoff } }
            longPointCache.removeAll(keepingCapacity: true)
            unsavedMinutes += 1
            if unsavedMinutes >= 10 { saveHistory() }
            minute = MinuteAccumulator()
        }
        minute.start = start
        minute.add(sample)
    }

    // MARK: Chart data
    /// Upper bound for the free-space chart: the size of the startup disk.
    var diskUpperBound: Double {
        if let total = info.diskSpaceTotal { return Double(total) / 1e9 }
        return max(history.compactMap(\.diskSpaceAvailable).max() ?? 1, 1)
    }

    /// Upper bound for network charts: the recent peak plus headroom, at least 1 MB/s.
    var networkUpperBound: Double { networkUpperBound(for: .minute) }

    func networkUpperBound(for range: HistoryRange) -> Double {
        let points = points(for: \.download, range: range) + points(for: \.upload, range: range)
        return max((points.map(\.value).max() ?? 0) * 1.2, 1)
    }

    /// Points for one metric, split into segments wherever readings are missing or
    /// sampling paused, so the chart never draws a line across a gap.
    func points(for keyPath: KeyPath<ReadingSample, Double?>, range: HistoryRange = .minute) -> [MetricPoint] {
        guard range != .minute else {
            let samples = history                      // read first so SwiftUI tracks changes
            if let cached = pointCache[keyPath] { return cached }
            let points = Self.segmented(samples, keyPath: keyPath, gap: 12)
            pointCache[keyPath] = points
            return points
        }
        let samples = minuteHistory
        let key = "\(keyPath.hashValue)-\(range.rawValue)"
        if let cached = longPointCache[key] { return cached }
        let cutoff = Date().addingTimeInterval(-range.seconds)
        let recent = samples.filter { $0.date >= cutoff }
        // At most ~240 points per chart keeps redraws cheap even for the 7-day view.
        let stride = max(1, recent.count / 240)
        let reduced = stride == 1 ? recent : Swift.stride(from: 0, to: recent.count, by: stride).compactMap {
            ReadingSample.average(recent[$0..<min($0 + stride, recent.count)])
        }
        let points = Self.segmented(reduced, keyPath: keyPath, gap: Double(stride) * 60 * 3)
        longPointCache[key] = points
        return points
    }

    private static func segmented(_ samples: [ReadingSample], keyPath: KeyPath<ReadingSample, Double?>,
                                  gap: TimeInterval) -> [MetricPoint] {
        var segment = 0
        var previousDate: Date?
        return samples.compactMap { sample -> MetricPoint? in
            defer { previousDate = sample.date }
            if let previousDate, sample.date.timeIntervalSince(previousDate) > gap { segment += 1 }
            guard let value = sample[keyPath: keyPath] else {
                segment += 1
                return nil
            }
            return MetricPoint(id: sample.id, date: sample.date, value: value, segment: segment)
        }
    }
}

// MARK: - Chart samples
/// A reading converted to chart units (percent, GB, MB/s).
struct ReadingSample: Identifiable, Codable {
    var id = UUID()
    let date: Date
    let cpuUsage: Double?
    let memoryUsage: Double?
    let diskSpaceAvailable: Double?
    let download: Double?
    let upload: Double?
    var gpuUsage: Double?

    private enum CodingKeys: String, CodingKey {
        case date, cpuUsage, memoryUsage, diskSpaceAvailable, download, upload, gpuUsage
    }

    init(date: Date, info: SystemInfo) {
        self.date = date
        cpuUsage = info.cpuUsage
        memoryUsage = info.memoryUsage.map { Double($0) / 1e9 }
        diskSpaceAvailable = info.diskSpaceAvailable.map { Double($0) / 1e9 }
        download = info.downloadRate.map { $0 / 1e6 }
        upload = info.uploadRate.map { $0 / 1e6 }
        gpuUsage = info.gpuUsage
    }

    init(date: Date, cpuUsage: Double?, memoryUsage: Double?, diskSpaceAvailable: Double?,
         download: Double?, upload: Double?, gpuUsage: Double?) {
        self.date = date
        self.cpuUsage = cpuUsage
        self.memoryUsage = memoryUsage
        self.diskSpaceAvailable = diskSpaceAvailable
        self.download = download
        self.upload = upload
        self.gpuUsage = gpuUsage
    }

    /// Mean of each metric over a run of samples, dated at the first sample.
    static func average<C: Collection>(_ samples: C) -> ReadingSample? where C.Element == ReadingSample {
        guard let first = samples.first else { return nil }
        func mean(_ keyPath: KeyPath<ReadingSample, Double?>) -> Double? {
            let values = samples.compactMap { $0[keyPath: keyPath] }
            return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
        return ReadingSample(date: first.date, cpuUsage: mean(\.cpuUsage), memoryUsage: mean(\.memoryUsage),
                             diskSpaceAvailable: mean(\.diskSpaceAvailable), download: mean(\.download),
                             upload: mean(\.upload), gpuUsage: mean(\.gpuUsage))
    }
}

struct MetricPoint: Identifiable {
    let id: UUID
    let date: Date
    let value: Double
    let segment: Int
}

/// Collects the samples that fall in the current minute.
private struct MinuteAccumulator {
    var start: Date?
    private var samples: [ReadingSample] = []

    mutating func add(_ sample: ReadingSample) { samples.append(sample) }

    func average() -> ReadingSample? {
        guard let start, let average = ReadingSample.average(samples) else { return nil }
        return ReadingSample(date: start, cpuUsage: average.cpuUsage, memoryUsage: average.memoryUsage,
                             diskSpaceAvailable: average.diskSpaceAvailable, download: average.download,
                             upload: average.upload, gpuUsage: average.gpuUsage)
    }
}

// MARK: - History persistence
/// Stores the per-minute history in Application Support so charts survive restarts.
enum HistoryStore {
    static var url: URL {
        AppSupport.folder.appendingPathComponent("history.json")
    }

    static func load() -> [ReadingSample] {
        guard let data = try? Data(contentsOf: url),
              let samples = try? JSONDecoder().decode([ReadingSample].self, from: data) else { return [] }
        let cutoff = Date().addingTimeInterval(-HistoryRange.week.seconds)
        return samples.filter { $0.date >= cutoff }
    }

    static func save(_ samples: [ReadingSample]) {
        guard let data = try? JSONEncoder().encode(samples) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func clear() { try? FileManager.default.removeItem(at: url) }
}

/// ~/Library/Application Support/System Monitor, created on first use.
nonisolated enum AppSupport {
    static var folder: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("System Monitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
