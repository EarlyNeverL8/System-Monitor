import SwiftUI
import AppKit
import Charts

// MARK: - Shared page building blocks
/// Large title + subtitle used at the top of every dashboard page.
struct PageHeader: View {
    let title: String
    let symbol: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.largeTitle.bold())
                .foregroundStyle(.purple)
            Text(subtitle).foregroundStyle(.secondary)
        }
    }
}

/// Small labelled value tile used on the Battery, Network and Performance pages.
struct StatTile: View {
    let title: String
    let value: String
    let symbol: String
    var tint: Color = .purple

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tint == .purple ? .primary : tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14)
        .accessibilityElement(children: .combine)
    }
}

/// Rounded card background shared by all dashboard sections.
struct CardModifier: ViewModifier {
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.purple.opacity(0.12)))
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View { modifier(CardModifier(padding: padding)) }
}

extension Binding where Value == Bool {
    /// True while `optional` holds a value; setting false clears it. Drives alerts
    /// that are presented for a pending item.
    init<Wrapped>(isPresent optional: Binding<Wrapped?>) {
        self.init(get: { optional.wrappedValue != nil },
                  set: { if !$0 { optional.wrappedValue = nil } })
    }
}

// MARK: - File icons
/// Finder icons keyed by path. List rows redraw often (Heavy Consumers refreshes
/// every 2 s), so each icon is looked up once instead of on every redraw.
enum FileIcon {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for path: String) -> Image {
        if let cached = cache.object(forKey: path as NSString) { return Image(nsImage: cached) }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(icon, forKey: path as NSString)
        return Image(nsImage: icon)
    }
}

// MARK: - Live sparkline chart
/// A line + area chart (60 seconds by default). Kept deliberately light (no animation, no
/// interpolation) because it redraws every second.
struct LiveChart: View {
    let points: [MetricPoint]
    let color: Color
    let upperBound: Double
    let latestDate: Date
    var unit: String = ""
    var showsAxis = false
    var span: TimeInterval = 60

    var body: some View {
        Chart {
            ForEach(points) { point in
                AreaMark(x: .value("Time", point.date),
                         yStart: .value("Baseline", 0),
                         yEnd: .value(unit, point.value),
                         series: .value("Segment", point.segment))
                    .foregroundStyle(color.opacity(0.14))
                LineMark(x: .value("Time", point.date),
                         y: .value(unit, point.value),
                         series: .value("Segment", point.segment))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(color)
            }
        }
        .chartXScale(domain: latestDate.addingTimeInterval(-span)...latestDate)
        .chartYScale(domain: 0...max(upperBound, 0.001))
        .chartXAxis(.hidden)
        .chartYAxis {
            if showsAxis {
                AxisMarks(position: .leading, values: [0, upperBound / 2, upperBound]) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4]))
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(number.formatted(.number.precision(.fractionLength(0...1))) + unit).font(.caption2)
                        }
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}
