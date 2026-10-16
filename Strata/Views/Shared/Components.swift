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

struct TimePoint: Identifiable {
    let id: Int
    let date: Date
    let value: Double
}

/// System history in thin lines over a faint fill, with a hover readout.
struct HistoryChart: View {
    let samples: [HistorySample]
    let series: [Series]
    var maxValue: Double?
    var minimumTop: Double = 1
    var format: (Double) -> String = { Fmt.percent($0) }
    var height: CGFloat = 116

    var body: some View {
        let lines = series.map { s in LineChart.Line(name: s.name, color: s.color, values: samples.map { $0[keyPath: s.value] }) }
        LineChart(lines: lines, dates: samples.map(\.date), top: maxValue, minimumTop: minimumTop, format: format, height: height)
    }

    /// The peak rounded up to 1, 2, 2.5 or 5 times a power of ten, so the
    /// axis reads in round numbers and doesn't twitch with every sample.
    static func nice(_ value: Double) -> Double {
        guard value > 0, value.isFinite else { return 1 }
        let magnitude = pow(10, floor(log10(value)))
        let step = [1, 2, 2.5, 5, 10].first { value <= $0 * magnitude } ?? 10
        return step * magnitude
    }
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

    var body: some View {
        LineChart(lines: [.init(name: "", color: color, values: points.map(\.value))], dates: points.map(\.date),
                  top: maxValue, minimumTop: minimumTop, unit: unit, format: format, height: height)
    }
}

/// A tiny line with no axes, for tiles and rows.
struct Sparkline: View {
    let values: [Double]
    var color: Color = Theme.series1
    var top: Double?
    var height: CGFloat = 26

    var body: some View {
        LineChart(lines: [.init(name: "", color: color, values: values)], dates: [], top: top ?? max(values.max() ?? 0, 1e-9),
                  format: { _ in "" }, height: height, axis: false)
    }
}

/// Lines as plain shapes: a path per series, a few grid lines and labels,
/// and a readout under the pointer. Shapes stay on Core Animation's ordinary
/// path; a `Canvas` (or a charting framework) would move the whole window onto
/// GPU drawables and cost tens of megabytes for a sparkline.
struct LineChart: View {
    struct Line {
        let name: String
        let color: Color
        let values: [Double]
    }

    let lines: [Line]
    let dates: [Date]
    var top: Double?
    var minimumTop: Double = 1
    var unit: Double = 1
    let format: (Double) -> String
    var height: CGFloat
    var axis = true

    @State private var hover: CGFloat?
    private static let gutter: CGFloat = 46

    var body: some View {
        let count = lines.map(\.values.count).max() ?? 0
        let peak = lines.flatMap(\.values).max() ?? 0
        let top = self.top ?? HistoryChart.nice(max(peak * 1.1, minimumTop) / unit) * unit
        GeometryReader { geo in
            let plot = CGSize(width: max(geo.size.width - (axis ? Self.gutter : 0), 1), height: geo.size.height)
            let index = hover.flatMap { x in count > 1 ? min(max(Int((x / plot.width * CGFloat(count - 1)).rounded()), 0), count - 1) : nil }
            let x = index.map { count > 1 ? plot.width * CGFloat($0) / CGFloat(count - 1) : 0 }
            ZStack(alignment: .topLeading) {
                if axis {
                    Path { path in
                        for value in [0, top / 2, top] {
                            let y = Trend.y(value, top: top, height: plot.height)
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: plot.width, y: y))
                        }
                    }
                    .stroke(Theme.grid, lineWidth: 1)
                    ForEach([0, top / 2, top], id: \.self) { value in
                        Text(format(value))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .frame(width: Self.gutter - 6, alignment: .leading)
                            .position(x: plot.width + 6 + (Self.gutter - 6) / 2,
                                      y: min(max(Trend.y(value, top: top, height: plot.height), 6), plot.height - 6))
                    }
                }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    let fade = lines.count == 1 ? 0.22 : 0.12
                    Trend(values: line.values, count: count, top: top, area: true)
                        .fill(LinearGradient(colors: [line.color.opacity(fade), line.color.opacity(0)], startPoint: .top, endPoint: .bottom))
                        .frame(width: plot.width, height: plot.height)
                    Trend(values: line.values, count: count, top: top, area: false)
                        .stroke(line.color, style: StrokeStyle(lineWidth: axis ? 1.75 : 1.5, lineCap: .round, lineJoin: .round))
                        .frame(width: plot.width, height: plot.height)
                }
                if let index, let x, axis {
                    Rectangle().fill(.secondary.opacity(0.5)).frame(width: 1, height: plot.height).position(x: x, y: plot.height / 2)
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        if index < line.values.count {
                            Circle().fill(line.color).frame(width: 7, height: 7)
                                .position(x: x, y: Trend.y(line.values[index], top: top, height: plot.height))
                        }
                    }
                    readout(index).fixedSize()
                        .alignmentGuide(.leading) { d in -min(max(x - d.width / 2, 0), max(plot.width - d.width, 0)) }
                        .offset(y: -6)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(.rect)
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hover = axis ? p.x : nil
                case .ended: hover = nil
                }
            }
        }
        .frame(height: height)
    }

    private func readout(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if index < dates.count { Text(dates[index], style: .time).font(.system(size: 10)).foregroundStyle(.secondary) }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if index < line.values.count {
                    HStack(spacing: 5) {
                        if lines.count > 1 {
                            Swatch(color: line.color)
                            Text(line.name).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                        }
                        Text(format(line.values[index])).monospacedDigit()
                    }
                    .font(.system(size: 11))
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .surface(radius: 8)
    }
}

/// A series as a smooth curve (or the area under it) across the full width.
struct Trend: Shape {
    let values: [Double]
    let count: Int
    let top: Double
    let area: Bool

    func path(in rect: CGRect) -> Path {
        guard count > 1, values.count > 1 else { return Path() }
        let offset = count - values.count
        let points = values.enumerated().map { i, v in
            CGPoint(x: rect.width * CGFloat(i + offset) / CGFloat(count - 1), y: Self.y(v, top: top, height: rect.height))
        }
        var path = Self.monotone(points)
        if area {
            path.addLine(to: CGPoint(x: points[points.count - 1].x, y: rect.height))
            path.addLine(to: CGPoint(x: points[0].x, y: rect.height))
            path.closeSubpath()
        }
        return path
    }

    static func y(_ value: Double, top: Double, height: CGFloat) -> CGFloat {
        let v = value.isFinite ? min(max(value, 0), top) : 0
        return height - CGFloat(v / max(top, 1e-12)) * height
    }

    /// A smooth curve through the points that never overshoots them
    /// (Fritsch–Carlson monotone cubic), so a flat line stays flat.
    static func monotone(_ p: [CGPoint]) -> Path {
        var path = Path()
        path.move(to: p[0])
        let n = p.count
        guard n > 2 else { path.addLine(to: p[1]); return path }
        var d = [CGFloat](repeating: 0, count: n - 1)
        for i in 0..<n - 1 { d[i] = (p[i + 1].y - p[i].y) / max(p[i + 1].x - p[i].x, 1e-6) }
        var m = [CGFloat](repeating: 0, count: n)
        m[0] = d[0]
        m[n - 1] = d[n - 2]
        for i in 1..<n - 1 { m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2 }
        for i in 0..<n - 1 where d[i] != 0 {
            let a = m[i] / d[i], b = m[i + 1] / d[i]
            let s = a * a + b * b
            if s > 9 {
                let t = 3 / s.squareRoot()
                m[i] = t * a * d[i]
                m[i + 1] = t * b * d[i]
            }
        }
        for i in 0..<n - 1 {
            let h = (p[i + 1].x - p[i].x) / 3
            path.addCurve(to: p[i + 1],
                          control1: CGPoint(x: p[i].x + h, y: p[i].y + m[i] * h),
                          control2: CGPoint(x: p[i + 1].x - h, y: p[i + 1].y - m[i + 1] * h))
        }
        return path
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

