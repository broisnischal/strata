import SwiftUI

struct TrackedView: View {
    @Environment(SystemMonitor.self) private var monitor
    @State private var picking = false
    @State private var editing: TrackedTarget?

    var body: some View {
        let tracking = monitor.tracking
        Group {
            if tracking.targets.isEmpty {
                ContentUnavailableView {
                    Label("Nothing Tracked", systemImage: "pin")
                } description: {
                    Text("Track an app or process to follow its CPU, memory and power over time, keep its peaks, and get an alert when it goes over a limit or stops.")
                } actions: {
                    Button("Choose a Running App…") { picking = true }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.canvas)
            } else {
                Page {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 440), spacing: Theme.gap, alignment: .top)], spacing: Theme.gap) {
                        ForEach(tracking.targets) { target in
                            TrackedCard(target: target) { editing = target }
                        }
                    }
                }
            }
        }
        .navigationTitle("Tracked")
        .toolbar {
            ToolbarItem {
                Button { picking = true } label: { Label("Track", systemImage: "plus") }
                    .help("Track a running app or process")
            }
        }
        .sheet(isPresented: $picking) { TrackPicker() }
        .sheet(item: $editing) { TrackedLimitsSheet(target: $0) }
    }
}

private struct TrackedCard: View {
    @Environment(SystemMonitor.self) private var monitor
    let target: TrackedTarget
    let edit: () -> Void

    var body: some View {
        let tracking = monitor.tracking
        let s = tracking.status[target.id] ?? TrackedStatus()
        let points = window(tracking.history[target.id] ?? [])
        Card(target.title) {
            Menu {
                Button("Limits and Alerts…", action: edit)
                Button("Reset Peaks") { tracking.resetPeaks(target.id) }
                if let path = target.appPath { Button("Reveal in Finder") { reveal(path) } }
                Divider()
                Button("Stop Tracking", role: .destructive) { tracking.untrack(target.id) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        } content: {
            HStack(spacing: 10) {
                Image(nsImage: IconCache.icon(forBundle: target.appPath)).resizable().frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.kindLabel).font(Theme.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    if s.running {
                        HStack(spacing: 4) {
                            StatusDot(color: Severity.good.color)
                            Text("\(s.pids.count) process\(s.pids.count == 1 ? "" : "es")")
                            if let since = s.since { Text("· running \(Text(since, style: .relative))").foregroundStyle(.secondary) }
                        }
                        .font(Theme.caption)
                    } else {
                        HStack(spacing: 4) {
                            StatusDot(color: Theme.neutral)
                            Text("Not running").foregroundStyle(.secondary)
                        }
                        .font(Theme.caption)
                    }
                }
            }
            HStack(alignment: .top, spacing: 18) {
                Stat(label: "CPU", value: Fmt.cpu(s.cpu) + "%")
                Stat(label: "Memory", value: Fmt.bytes(s.memory))
                Stat(label: "Power", value: Fmt.watts(s.power))
                Stat(label: "Peak CPU", value: Fmt.cpu(s.peakCPU) + "%")
                Stat(label: "Peak memory", value: Fmt.bytes(s.peakMemory))
                Stat(label: "Avg CPU", value: Fmt.cpu(s.averageCPU) + "%")
            }
            HStack(alignment: .top, spacing: 16) {
                chart("CPU", points.map { TimePoint(id: $0.id, date: $0.date, value: $0.cpu) }, minimumTop: 10, unit: 1) { Fmt.cpuAxis($0) }
                chart("Memory", points.map { TimePoint(id: $0.id, date: $0.date, value: $0.memory) }, minimumTop: 67_108_864, unit: 1_048_576) { Fmt.bytes(UInt64(max($0, 0))) }
            }
            if let limits = limitsText {
                Label(limits, systemImage: "bell").font(Theme.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func chart(_ title: String, _ points: [TimePoint], minimumTop: Double, unit: Double, format: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.caption).foregroundStyle(.secondary)
            TimeChart(points: points, minimumTop: minimumTop, unit: unit, format: format, height: 70)
        }
        .frame(maxWidth: .infinity)
    }

    private var limitsText: String? {
        var parts: [String] = []
        if let m = target.memoryLimit { parts.append("over \(Fmt.bytes(m))") }
        if let c = target.cpuLimit { parts.append("over \(Fmt.cpu(c))% CPU") }
        if target.alertOnExit { parts.append("when it stops") }
        return parts.isEmpty ? nil : "Alerts " + parts.joined(separator: " · ")
    }

    /// The points inside the chosen history window, averaged down for drawing.
    private func window(_ all: [TrackedPoint]) -> [TrackedPoint] {
        let cutoff = (all.last?.date ?? .now).addingTimeInterval(-Double(monitor.window.rawValue))
        let slice = all.drop { $0.date < cutoff }
        let size = max(1, Int((Double(slice.count) / Double(SystemMonitor.chartPoints)).rounded(.up)))
        guard size > 1 else { return Array(slice) }
        return stride(from: slice.startIndex, to: slice.endIndex, by: size).map { i in
            let chunk = slice[i..<min(i + size, slice.endIndex)]
            let n = Double(chunk.count)
            let last = chunk[chunk.endIndex - 1]
            return TrackedPoint(id: last.id, date: last.date, cpu: chunk.reduce(0) { $0 + $1.cpu } / n,
                                memory: chunk.reduce(0) { $0 + $1.memory } / n, power: chunk.reduce(0) { $0 + $1.power } / n)
        }
    }
}

/// Running apps and processes to choose from.
private struct TrackPicker: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selection: String?

    private struct Candidate: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let icon: String?
        let process: ProcessSample
        let memory: UInt64
    }

    var body: some View {
        let candidates = candidates
        VStack(spacing: 0) {
            HStack {
                Text("Track an App or Process").font(.headline)
                Spacer()
            }
            .padding(16)
            TextField("Search", text: $search).textFieldStyle(.roundedBorder).padding(.horizontal, 16).padding(.bottom, 10)
            List(candidates, selection: $selection) { c in
                HStack(spacing: 8) {
                    Image(nsImage: IconCache.icon(forBundle: c.icon)).resizable().frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.title)
                        Text(c.subtitle).font(Theme.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Fmt.bytes(c.memory)).monospacedDigit().foregroundStyle(.secondary)
                }
                .tag(c.id)
            }
            .listStyle(.inset)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Track") {
                    if let c = candidates.first(where: { $0.id == selection }) { monitor.tracking.track(c.process) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
            .padding(12)
        }
        .frame(width: 460, height: 520)
    }

    /// One row per app (its helpers folded in) and per name outside apps,
    /// biggest first.
    private var candidates: [Candidate] {
        var groups: [String: [ProcessSample]] = [:]
        for p in monitor.processes { groups[p.appPath ?? "name:" + p.name, default: []].append(p) }
        let query = search.trimmingCharacters(in: .whitespaces)
        return groups.compactMap { key, procs -> Candidate? in
            guard let first = procs.first, monitor.tracking.target(for: first) == nil else { return nil }
            let app = first.appPath
            let title = app.map { ($0 as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "") } ?? first.name
            if !query.isEmpty, !title.localizedCaseInsensitiveContains(query) { return nil }
            let subtitle = app != nil ? "\(procs.count) process\(procs.count == 1 ? "" : "es")" : "Process · \(procs.count) running"
            return Candidate(id: key, title: title, subtitle: subtitle, icon: app, process: first, memory: procs.reduce(0) { $0 + $1.memory })
        }
        .sorted { $0.memory > $1.memory }
    }
}

private struct TrackedLimitsSheet: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(\.dismiss) private var dismiss
    @State var target: TrackedTarget
    @State private var memoryOn = false
    @State private var memoryGB = 2.0
    @State private var cpuOn = false
    @State private var cpuPercent = 100.0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section(target.title) {
                    HStack {
                        Toggle("Alert when memory is over", isOn: $memoryOn)
                        Spacer()
                        Stepper(value: $memoryGB, in: 0.25...64, step: 0.25) {
                            Text("\(memoryGB.formatted(.number.precision(.fractionLength(0...2)))) GB").monospacedDigit()
                        }
                        .disabled(!memoryOn)
                    }
                    HStack {
                        Toggle("Alert when CPU stays over", isOn: $cpuOn)
                        Spacer()
                        Stepper(value: $cpuPercent, in: 10...1600, step: 10) {
                            Text("\(Int(cpuPercent))%").monospacedDigit()
                        }
                        .disabled(!cpuOn)
                    }
                    Toggle("Alert when it stops running", isOn: $target.alertOnExit)
                }
            }
            .formStyle(.grouped)
            HStack {
                Text("100% CPU is one full core.").font(Theme.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    target.memoryLimit = memoryOn ? UInt64(memoryGB * 1_073_741_824) : nil
                    target.cpuLimit = cpuOn ? cpuPercent : nil
                    monitor.tracking.update(target)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 440)
        .onAppear {
            memoryOn = target.memoryLimit != nil
            memoryGB = target.memoryLimit.map { Double($0) / 1_073_741_824 } ?? 2
            cpuOn = target.cpuLimit != nil
            cpuPercent = target.cpuLimit ?? 100
        }
    }
}
