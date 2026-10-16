import Charts
import SwiftUI

// MARK: - Layout

/// A page's scrolling canvas. Snapshots render it unscrolled.
struct Page<Content: View>: View {
    @Environment(\.snapshotting) private var snapshotting
    @ViewBuilder var content: Content

    var body: some View {
        Group {
            if snapshotting {
                content.padding(20).frame(maxWidth: .infinity, alignment: .topLeading)
            } else {
                ScrollView { content.padding(20) }
            }
        }
        .background(Theme.canvas)
    }
}

struct Card<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(_ title: String, icon: String? = nil, @ViewBuilder accessory: () -> Accessory = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(Theme.title).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                accessory.font(Theme.caption).foregroundStyle(.secondary)
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .surface()
    }
}

/// Columns at least `minWidth` wide; the cards in a row take the height of
/// the tallest, so rows line up instead of leaving ragged gaps.
struct CardGrid: Layout {
    var minWidth: CGFloat = 360
    var spacing: CGFloat = Theme.gap

    private func rows(_ subviews: Subviews, width: CGFloat) -> (columns: Int, width: CGFloat, heights: [CGFloat]) {
        let n = max(1, Int((width + spacing) / (minWidth + spacing)))
        let column = (width - spacing * CGFloat(n - 1)) / CGFloat(n)
        let heights = stride(from: 0, to: subviews.count, by: n).map { start in
            subviews[start..<min(start + n, subviews.count)]
                .map { $0.sizeThatFits(ProposedViewSize(width: column, height: nil)).height }.max() ?? 0
        }
        return (n, column, heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minWidth * 2 + spacing
        let heights = rows(subviews, width: width).heights
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(heights.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (n, column, heights) = rows(subviews, width: bounds.width)
        var y = bounds.minY
        for (row, height) in heights.enumerated() {
            for c in 0..<n where row * n + c < subviews.count {
                subviews[row * n + c].place(
                    at: CGPoint(x: bounds.minX + CGFloat(c) * (column + spacing), y: y),
                    proposal: ProposedViewSize(width: column, height: height)
                )
            }
            y += height + spacing
        }
    }
}

/// A quiet text button, for "Show all" and the like.
struct TextButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) { Text(title).foregroundStyle(.tint) }.buttonStyle(.plain)
    }
}

extension View {
    /// The card surface: a quiet fill with a hairline edge, no shadow.
    func surface(radius: CGFloat = Theme.radius) -> some View {
        background(Theme.surface, in: .rect(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.hairline))
    }
}

// MARK: - Numbers

struct BigValue: View {
    let value: String
    var caption: String?
    var small = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value).font(small ? Theme.metricSmall : Theme.metric)
            if let caption { Text(caption).font(.system(size: 12)).foregroundStyle(.secondary) }
        }
        .lineLimit(1)
    }
}

/// A small label over a value: the stat tile's anatomy.
struct Stat: View {
    let label: String
    let value: String
    var color: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if let color { Swatch(color: color) }
                Text(label).font(Theme.caption).foregroundStyle(.secondary)
            }
            Text(value).font(.system(size: 13, weight: .medium)).monospacedDigit().lineLimit(1)
        }
    }
}

struct Swatch: View {
    let color: Color
    var body: some View { RoundedRectangle(cornerRadius: 2, style: .continuous).fill(color).frame(width: 8, height: 8) }
}

struct LegendItem: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Swatch(color: color)
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).monospacedDigit()
        }
        .font(.system(size: 12))
    }
}

struct StatusLabel: View {
    let severity: Severity
    var text: String?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: severity.icon).foregroundStyle(severity.color)
            Text(text ?? severity.label)
        }
        .font(.system(size: 11, weight: .medium))
    }
}

// MARK: - Charts

struct Series: Identifiable {
    let name: String
    let color: Color
    let value: KeyPath<HistorySample, Double>
    var id: String { name }
}

/// A time series in thin lines over a faint fill, with a hover readout.
struct HistoryChart: View {
    let samples: [HistorySample]
    let series: [Series]
    var maxValue: Double?
    var minimumTop: Double = 1
    var format: (Double) -> String = { Fmt.percent($0) }
    var height: CGFloat = 116

    @State private var hover: Date?

    var body: some View {
        let top = maxValue ?? niceTop
        let hovered = hover.flatMap(nearest)
        Chart {
            ForEach(series) { s in
                ForEach(samples) { sample in
                    AreaMark(
                        x: .value("Time", sample.date),
                        y: .value(s.name, min(sample[keyPath: s.value], top)),
                        series: .value("Series", s.name),
                        stacking: .unstacked
                    )
                    .foregroundStyle(LinearGradient(colors: [s.color.opacity(series.count == 1 ? 0.22 : 0.12), s.color.opacity(0)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                    LineMark(
                        x: .value("Time", sample.date),
                        y: .value(s.name, min(sample[keyPath: s.value], top)),
                        series: .value("Series", s.name)
                    )
                    .foregroundStyle(s.color)
                    .lineStyle(StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
                }
            }
            if let hovered {
                RuleMark(x: .value("Time", hovered.date))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        Readout(sample: hovered, series: series, format: format)
                    }
                ForEach(series) { s in
                    PointMark(x: .value("Time", hovered.date), y: .value(s.name, min(hovered[keyPath: s.value], top)))
                        .foregroundStyle(s.color)
                        .symbolSize(28)
                }
            }
        }
        .chartXSelection(value: $hover)
        .chartXAxis(.hidden)
        .chartYScale(domain: 0...top)
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, top / 2, top]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(Theme.grid)
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(format(v)).font(.system(size: 9.5)).foregroundStyle(.tertiary) }
                }
            }
        }
        .frame(height: height)
        .transaction { $0.animation = nil }
    }

    private func nearest(_ date: Date) -> HistorySample? {
        samples.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    /// The peak rounded up to 1, 2, 2.5 or 5 times a power of ten, so the
    /// axis reads in round numbers and doesn't twitch with every sample.
    private var niceTop: Double {
        let peak = samples.reduce(0.0) { acc, sample in max(acc, series.map { sample[keyPath: $0.value] }.max() ?? 0) }
        return Self.nice(max(peak * 1.1, minimumTop))
    }

    static func nice(_ value: Double) -> Double {
        guard value > 0, value.isFinite else { return 1 }
        let magnitude = pow(10, floor(log10(value)))
        let step = [1, 2, 2.5, 5, 10].first { value <= $0 * magnitude } ?? 10
        return step * magnitude
    }
}

private struct Readout: View {
    let sample: HistorySample
    let series: [Series]
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(sample.date, style: .time).font(.system(size: 10)).foregroundStyle(.secondary)
            ForEach(series) { s in
                HStack(spacing: 5) {
                    Swatch(color: s.color)
                    Text(s.name).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(format(sample[keyPath: s.value])).monospacedDigit()
                }
                .font(.system(size: 11))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(minWidth: 120)
        .surface(radius: 8)
    }
}

struct TimePoint: Identifiable {
    let id: Int
    let date: Date
    let value: Double
}

/// One measure over time, with the same anatomy as `HistoryChart`.
struct TimeChart: View {
    let points: [TimePoint]
    var color: Color = Theme.series1
    var maxValue: Double?
    var minimumTop: Double = 1
    /// The axis rounds in this unit (1 MiB for memory), so it reads "512 MB".
    var unit: Double = 1
    var format: (Double) -> String
    var height: CGFloat = 80

    @State private var hover: Date?

    var body: some View {
        let top = maxValue ?? HistoryChart.nice(max((points.map(\.value).max() ?? 0) * 1.1, minimumTop) / unit) * unit
        let hovered = hover.flatMap { d in points.min { abs($0.date.timeIntervalSince(d)) < abs($1.date.timeIntervalSince(d)) } }
        Chart {
            ForEach(points) { p in
                AreaMark(x: .value("Time", p.date), y: .value("Value", min(p.value, top)))
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.2), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", p.date), y: .value("Value", min(p.value, top)))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            if let hovered {
                RuleMark(x: .value("Time", hovered.date))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hovered.date, style: .time).font(.system(size: 10)).foregroundStyle(.secondary)
                            Text(format(hovered.value)).font(.system(size: 11)).monospacedDigit()
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .surface(radius: 8)
                    }
                PointMark(x: .value("Time", hovered.date), y: .value("Value", min(hovered.value, top)))
                    .foregroundStyle(color).symbolSize(28)
            }
        }
        .chartXSelection(value: $hover)
        .chartXAxis(.hidden)
        .chartYScale(domain: 0...top)
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, top / 2, top]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(Theme.grid)
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(format(v)).font(.system(size: 9.5)).foregroundStyle(.tertiary) }
                }
            }
        }
        .frame(height: height)
        .transaction { $0.animation = nil }
    }
}

/// A tiny line with no axes, for tiles and rows.
struct Sparkline: View {
    let values: [Double]
    var color: Color = Theme.series1
    var top: Double?
    var height: CGFloat = 26

    var body: some View {
        let peak = top ?? max(values.max() ?? 0, 1e-9)
        Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                AreaMark(x: .value("i", i), y: .value("v", min(v, peak)))
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.2), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("i", i), y: .value("v", min(v, peak)))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartXScale(domain: 0...max(values.count - 1, 1))
        .chartYScale(domain: 0...peak)
        .frame(height: height)
        .transaction { $0.animation = nil }
    }
}

// MARK: - Bars

struct SegmentedBar: View {
    struct Segment: Identifiable {
        let label: String
        let value: Double
        let color: Color
        var id: String { label }
    }

    let segments: [Segment]
    let total: Double
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(segments) { segment in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(segment.color)
                        .frame(width: max(0, geo.size.width * segment.value / max(total, 1) - 2))
                        .help("\(segment.label): \(Fmt.percent(segment.value / max(total, 1)))")
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .background(Theme.well, in: .rect(cornerRadius: 3, style: .continuous))
        .clipShape(.rect(cornerRadius: 3, style: .continuous))
    }
}

struct SizeBar: View {
    let fraction: Double
    var tint: Color = Theme.series1
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.well)
                Capsule().fill(tint).frame(width: max(height, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
    }
}

struct StatusDot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 7, height: 7) }
}

struct Badge: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(.primary.opacity(0.8))
            .background(tint.opacity(0.14), in: .capsule)
    }
}

// MARK: - States

struct LoadingView: View {
    let text: String
    var body: some View {
        ProgressView(text).controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorBanner: View {
    @Binding var message: String?

    var body: some View {
        if let message {
            HStack(spacing: 8) {
                Image(systemName: Severity.warning.icon).foregroundStyle(Severity.warning.color)
                Text(message).lineLimit(3).textSelection(.enabled)
                Spacer()
                Button("Dismiss") { self.message = nil }.buttonStyle(.borderless)
            }
            .font(.callout)
            .padding(10)
            .background(Severity.warning.color.opacity(0.1))
        }
    }
}

// MARK: - Snapshots

private struct SnapshottingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var snapshotting: Bool {
        get { self[SnapshottingKey.self] }
        set { self[SnapshottingKey.self] = newValue }
    }
}

// MARK: - Helpers

@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]
    private static let executable = NSWorkspace.shared.icon(for: .unixExecutable)

    static func icon(forBundle path: String?) -> NSImage {
        guard let path else { return executable }
        if let image = cache[path] { return image }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 32, height: 32)
        cache[path] = image
        return image
    }
}

extension View {
    func revealInFinderMenu(_ path: String?) -> some View {
        contextMenu {
            if let path {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                Button("Copy Path") { copyToPasteboard(path) }
            }
        }
    }
}

@MainActor
func copyToPasteboard(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}

@MainActor
func reveal(_ path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
}
