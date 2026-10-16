import SwiftUI

struct OverviewView: View {
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        @Bindable var monitor = monitor
        Page {
            VStack(spacing: Theme.gap) {
                ActiveAlertsStrip()
                CardGrid {
                    CPUCard()
                    MemoryCard()
                    GPUCard()
                    PowerCard()
                    NetworkCard()
                    DiskCard()
                    TopProcessesCard()
                    if !monitor.tracking.targets.isEmpty { TrackedSummaryCard() }
                    SystemInfoCard()
                }
            }
        }
        .navigationTitle("Overview")
        .toolbar {
            ToolbarItem {
                Picker("History", selection: $monitor.window) {
                    ForEach(HistoryWindow.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("How far back the charts look")
            }
        }
    }
}

// MARK: - Cards

private struct CPUCard: View {
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        let snap = monitor.snapshot
        Card("CPU") {
            Text("\(snap.cores.count) cores").monospacedDigit()
        } content: {
            HStack(alignment: .lastTextBaseline, spacing: 18) {
                BigValue(value: Fmt.percent(snap.cpu))
                Stat(label: "User", value: Fmt.percent(snap.cpuUser, digits: 1))
                Stat(label: "System", value: Fmt.percent(snap.cpuSystem, digits: 1))
                Stat(label: "Load", value: String(format: "%.2f", snap.loadAverage.first ?? 0))
            }
            HistoryChart(samples: monitor.visibleHistory, series: [Series(name: "CPU", color: Theme.series1, value: \.cpu)], maxValue: 1)
            CoreStrip(cores: snap.cores)
        }
    }
}

/// One thin bar per core, performance cores first, with the clusters labelled.
private struct CoreStrip: View {
    let cores: [CoreLoad]

    var body: some View {
        let groups = Dictionary(grouping: cores, by: \.kind)
        let order: [CoreKind] = [.performance, .efficiency, .unknown]
        HStack(alignment: .bottom, spacing: 12) {
            ForEach(order.filter { groups[$0] != nil }, id: \.self) { kind in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(groups[kind] ?? []) { core in
                            GeometryReader { geo in
                                VStack(spacing: 0) {
                                    Spacer(minLength: 0)
                                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                                        .fill(Theme.series1)
                                        .frame(height: max(2, geo.size.height * min(core.total, 1)))
                                }
                            }
                            .background(Theme.well, in: .rect(cornerRadius: 2, style: .continuous))
                            .help("Core \(core.id): \(Fmt.percent(core.total))")
                        }
                    }
                    .frame(height: 30)
                    Text(kind == .performance ? "Performance" : kind == .efficiency ? "Efficiency" : "Cores")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

private struct MemoryCard: View {
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        let m = monitor.snapshot.memory
        Card("Memory") {
            StatusLabel(severity: Severity(pressureLevel: m.pressureLevel), text: "Pressure \(m.pressureName.lowercased())")
        } content: {
            HStack(alignment: .lastTextBaseline, spacing: 18) {
                BigValue(value: Fmt.bytes(m.used), caption: "of \(Fmt.bytes(m.total))")
                Spacer(minLength: 0)
                Stat(label: "Swap", value: Fmt.bytes(m.swapUsed))
            }
            SegmentedBar(segments: [
                .init(label: "App", value: Double(m.app), color: Theme.series1),
                .init(label: "Wired", value: Double(m.wired), color: Theme.series2),
                .init(label: "Compressed", value: Double(m.compressed), color: Theme.series3),
                .init(label: "Cached", value: Double(m.cached), color: Theme.neutral),
            ], total: Double(m.total))
            Grid(horizontalSpacing: 20, verticalSpacing: 5) {
                GridRow {
                    LegendItem(color: Theme.series1, label: "App", value: Fmt.bytes(m.app))
                    LegendItem(color: Theme.series2, label: "Wired", value: Fmt.bytes(m.wired))
                }
                GridRow {
                    LegendItem(color: Theme.series3, label: "Compressed", value: Fmt.bytes(m.compressed))
                    LegendItem(color: Theme.neutral, label: "Cached", value: Fmt.bytes(m.cached))
                }
            }
            HistoryChart(samples: monitor.visibleHistory, series: [Series(name: "Used", color: Theme.series1, value: \.memoryUsed)],
                         maxValue: 1, height: 84)
        }
    }
}

private struct GPUCard: View {
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        Card("GPU") {
            BigValue(value: monitor.snapshot.gpu.map { Fmt.percent($0) } ?? "–", caption: "utilization")
            HistoryChart(samples: monitor.visibleHistory, series: [Series(name: "GPU", color: Theme.series1, value: \.gpu)], maxValue: 1)
        }
    }
}

private struct PowerCard: View {
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        let snap = monitor.snapshot
        let hasSystem = snap.systemPower != nil
        Card("Power") {
            if let b = snap.battery {
                Label(Fmt.percent(b.percent), systemImage: b.isCharging ? "battery.100percent.bolt" : batteryIcon(b.percent))
                    .monospacedDigit()
            }
        } content: {
            HStack(alignment: .lastTextBaseline, spacing: 18) {
                BigValue(value: Fmt.watts(snap.systemPower ?? monitor.processPower), caption: hasSystem ? "system" : "processes")
                if hasSystem { Stat(label: "Processes", value: Fmt.watts(monitor.processPower)) }
                if let b = snap.battery {
                    Stat(label: b.onAC ? (b.isCharging ? "Charging" : "Adapter") : "Remaining",
                         value: b.minutesRemaining.map { Fmt.duration(Double($0) * 60) } ?? "–")
                }
            }
            HistoryChart(samples: monitor.visibleHistory,
                         series: [Series(name: hasSystem ? "System" : "Processes", color: Theme.series1, value: hasSystem ? \.power : \.processPower)],
                         format: { Fmt.watts($0) })
        }
    }

    private func batteryIcon(_ p: Double) -> String {
        switch p {
        case ..<0.13: "battery.0percent"
        case ..<0.38: "battery.25percent"
        case ..<0.63: "battery.50percent"
        case ..<0.88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

private struct NetworkCard: View {
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        let snap = monitor.snapshot
        Card("Network") {
            HStack(spacing: 28) {
                LegendStat(color: Theme.series1, label: "In", value: Fmt.rate(snap.netIn), total: Fmt.fileBytes(snap.netTotalIn))
                LegendStat(color: Theme.series2, label: "Out", value: Fmt.rate(snap.netOut), total: Fmt.fileBytes(snap.netTotalOut))
            }
            HistoryChart(samples: monitor.visibleHistory, series: [
                Series(name: "In", color: Theme.series1, value: \.netIn),
                Series(name: "Out", color: Theme.series2, value: \.netOut),
            ], minimumTop: 10_000, format: { Fmt.rate($0) })
        }
    }
}

private struct DiskCard: View {
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        let snap = monitor.snapshot
        Card("Disk") {
            HStack(spacing: 28) {
                LegendStat(color: Theme.series1, label: "Read", value: Fmt.rate(snap.diskRead))
                LegendStat(color: Theme.series2, label: "Write", value: Fmt.rate(snap.diskWrite))
            }
            HistoryChart(samples: monitor.visibleHistory, series: [
                Series(name: "Read", color: Theme.series1, value: \.diskRead),
                Series(name: "Write", color: Theme.series2, value: \.diskWrite),
            ], minimumTop: 100_000, format: { Fmt.rate($0) })
        }
    }
}

/// A series' legend entry carrying its headline value.
private struct LegendStat: View {
    let color: Color
    let label: String
    let value: String
    var total: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Swatch(color: color)
                Text(label).font(Theme.caption).foregroundStyle(.secondary)
                if let total { Text("· \(total) total").font(Theme.caption).foregroundStyle(.tertiary) }
            }
            Text(value).font(Theme.metricSmall)
        }
    }
}

private struct TopProcessesCard: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(AppModel.self) private var model

    var body: some View {
        Card("Top Processes") {
            TextButton("Show all") { model.selection = .processes }
        } content: {
            VStack(spacing: 2) {
                ForEach(monitor.topProcesses) { p in
                    ProcessLine(process: p, tracked: monitor.tracking.target(for: p) != nil)
                }
            }
        }
    }
}

struct ProcessLine: View {
    let process: ProcessSample
    var tracked = false
    var showsBar = true

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: IconCache.icon(forBundle: process.bundlePath)).resizable().frame(width: 16, height: 16)
            Text(process.name).lineLimit(1).truncationMode(.middle)
            if tracked { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.tertiary) }
            Spacer(minLength: 8)
            if showsBar { SizeBar(fraction: process.cpu / 100, tint: Theme.series1, height: 4).frame(width: 56) }
            Text(Fmt.cpu(process.cpu) + "%").monospacedDigit().frame(width: 50, alignment: .trailing)
            Text(Fmt.bytes(process.memory)).monospacedDigit().foregroundStyle(.secondary).frame(width: 66, alignment: .trailing)
        }
        .font(.system(size: 12))
        .padding(.vertical, 4)
    }
}

private struct TrackedSummaryCard: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(AppModel.self) private var model

    var body: some View {
        let tracking = monitor.tracking
        Card("Tracked") {
            TextButton("Open") { model.selection = .tracked }
        } content: {
            VStack(spacing: 8) {
                ForEach(tracking.targets.prefix(5)) { t in
                    let s = tracking.status[t.id] ?? TrackedStatus()
                    HStack(spacing: 8) {
                        Image(nsImage: IconCache.icon(forBundle: t.appPath)).resizable().frame(width: 16, height: 16)
                        Text(t.title).lineLimit(1)
                        if !s.running { Text("not running").font(Theme.caption).foregroundStyle(.tertiary) }
                        Spacer(minLength: 8)
                        Sparkline(values: (tracking.history[t.id] ?? []).suffix(60).map(\.memory), height: 18).frame(width: 64)
                        Text(Fmt.cpu(s.cpu) + "%").monospacedDigit().frame(width: 50, alignment: .trailing)
                        Text(Fmt.bytes(s.memory)).monospacedDigit().foregroundStyle(.secondary).frame(width: 66, alignment: .trailing)
                    }
                    .font(.system(size: 12))
                }
            }
        }
    }
}

private struct SystemInfoCard: View {
    @Environment(SystemMonitor.self) private var monitor
    private let model = Sysctl.string("machdep.cpu.brand_string") ?? Sysctl.string("hw.model") ?? "Mac"
    private let os = ProcessInfo.processInfo.operatingSystemVersionString

    var body: some View {
        let snap = monitor.snapshot
        Card("System") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                row("Chip", model)
                row("macOS", os)
                row("Uptime", Fmt.duration(snap.uptime))
                row("Load average", snap.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: "  "))
                GridRow {
                    Text("Thermal").foregroundStyle(.secondary)
                    StatusLabel(severity: thermalSeverity(snap.thermal), text: snap.thermalName)
                }
                row("Processes", "\(monitor.processes.count) · \(monitor.threadCount) threads")
            }
            .font(.system(size: 12))
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit().textSelection(.enabled).lineLimit(1)
        }
    }

    private func thermalSeverity(_ t: ProcessInfo.ThermalState) -> Severity {
        switch t {
        case .critical: .critical
        case .serious: .serious
        case .fair: .warning
        default: .good
        }
    }
}

/// Conditions alerting right now, above everything else.
struct ActiveAlertsStrip: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(AppModel.self) private var model

    var body: some View {
        let active = monitor.alerts.activeSorted
        if !active.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(active.prefix(3).enumerated()), id: \.element.key) { i, e in
                    if i > 0 { Divider().padding(.leading, 40) }
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: e.severity.icon).foregroundStyle(e.severity.color).frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.title).font(.system(size: 12.5, weight: .medium))
                            Text(e.detail).font(Theme.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text(e.date, style: .relative).font(Theme.caption).foregroundStyle(.tertiary).monospacedDigit()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                Divider()
                TextButton("\(active.count) active · Open Alerts") { model.selection = .alerts }
                    .font(Theme.caption).padding(8)
            }
            .surface()
        }
    }
}
