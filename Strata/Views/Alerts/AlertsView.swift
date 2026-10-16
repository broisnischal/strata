import SwiftUI

struct AlertsView: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(AppModel.self) private var model

    var body: some View {
        let alerts = monitor.alerts
        Page {
            HStack(alignment: .top, spacing: Theme.gap) {
                VStack(spacing: Theme.gap) {
                    ActiveCard()
                    HistoryCard()
                }
                .frame(maxWidth: .infinity)
                RulesCard().frame(width: 380)
            }
        }
        .navigationTitle("Alerts")
        .toolbar {
            ToolbarItem {
                Button("Clear History", systemImage: "trash") { alerts.clearHistory() }
                    .disabled(alerts.events.isEmpty)
            }
        }
        .onAppear { alerts.markRead() }
        .onChange(of: alerts.events.first?.id) { if model.selection == .alerts { alerts.markRead() } }
    }
}

private struct ActiveCard: View {
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        let active = monitor.alerts.activeSorted
        Card("Now") {
            Text(active.isEmpty ? "" : "\(active.count) active")
        } content: {
            if active.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: Severity.good.icon).foregroundStyle(Severity.good.color)
                    Text("Everything is within your limits.").foregroundStyle(.secondary)
                }
                .font(.system(size: 12.5))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(active.enumerated()), id: \.element.key) { i, e in
                        if i > 0 { Divider().padding(.leading, 28) }
                        EventRow(event: e, relative: true)
                    }
                }
            }
        }
    }
}

private struct HistoryCard: View {
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        let events = monitor.alerts.events
        Card("History") {
            Text(events.isEmpty ? "" : "\(events.count) alerts")
        } content: {
            if events.isEmpty {
                Text("Alerts appear here as they happen, and stay after you quit.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(events.prefix(200).enumerated()), id: \.element.id) { i, e in
                        if i > 0 { Divider().padding(.leading, 28) }
                        EventRow(event: e, relative: false)
                    }
                }
            }
        }
    }
}

private struct EventRow: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(AppModel.self) private var model
    let event: AlertEvent
    let relative: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: event.severity.icon).foregroundStyle(event.severity.color).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.system(size: 12.5, weight: .medium))
                if !event.detail.isEmpty {
                    Text(event.detail).font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Group {
                if relative {
                    Text(event.date, style: .relative)
                } else {
                    Text(event.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                }
            }
            .font(Theme.caption).foregroundStyle(.tertiary).monospacedDigit()
        }
        .padding(.vertical, 8)
        .contentShape(.rect)
        .contextMenu {
            if let pid = event.pid, monitor.processes.contains(where: { $0.pid == pid }) {
                Button("Show Process") { model.reveal(pid: pid) }
            }
            Button("Copy") { copyToPasteboard("\(event.title)\n\(event.detail)") }
        }
    }
}

private struct RulesCard: View {
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        @Bindable var alerts = monitor.alerts
        Card("Rules") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Send notifications", isOn: $alerts.rules.notify)
                Divider()
                Group {
                    Toggle("Memory pressure goes up", isOn: $alerts.rules.memoryPressure)
                    RuleRow(title: "Memory used over", threshold: $alerts.rules.memoryUsed, unit: "%", range: 50...99, step: 1)
                    RuleRow(title: "Swap over", threshold: $alerts.rules.swap, unit: "GB", range: 1...64, step: 1)
                    RuleRow(title: "CPU over", threshold: $alerts.rules.systemCPU, unit: "%", range: 30...100, step: 5, duration: true)
                    RuleRow(title: "A process's CPU over", threshold: $alerts.rules.processCPU, unit: "%", range: 25...1600, step: 25, duration: true)
                    RuleRow(title: "A process's memory over", threshold: $alerts.rules.processMemory, unit: "GB", range: 0.5...64, step: 0.5)
                    RuleRow(title: "Free disk under", threshold: $alerts.rules.diskFree, unit: "GB", range: 1...500, step: 1)
                    RuleRow(title: "Battery under", threshold: $alerts.rules.battery, unit: "%", range: 5...50, step: 5)
                    Toggle("The Mac runs hot", isOn: $alerts.rules.thermal)
                }
                Divider()
                HStack {
                    Text("Repeat a lasting alert every")
                    Spacer()
                    Stepper(value: $alerts.rules.cooldownMinutes, in: 1...240, step: 5) {
                        Text("\(Int(alerts.rules.cooldownMinutes)) min").monospacedDigit()
                    }
                }
                Text("Process CPU counts 100% per core. Tracked apps have their own limits on the Tracked page.")
                    .font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 12.5))
            .toggleStyle(.checkbox)
        }
    }
}

private struct RuleRow: View {
    let title: String
    @Binding var threshold: Threshold
    let unit: String
    let range: ClosedRange<Double>
    let step: Double
    var duration = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle(title, isOn: $threshold.enabled)
                Spacer()
                Stepper(value: $threshold.value, in: range, step: step) {
                    Text("\(threshold.value.formatted(.number.precision(.fractionLength(0...1)))) \(unit)").monospacedDigit()
                }
                .disabled(!threshold.enabled)
            }
            if duration {
                HStack {
                    Text("for").foregroundStyle(.secondary).padding(.leading, 20)
                    Spacer()
                    Stepper(value: $threshold.seconds, in: 10...1800, step: threshold.seconds < 120 ? 10 : 60) {
                        Text(Fmt.duration(threshold.seconds)).monospacedDigit()
                    }
                    .disabled(!threshold.enabled)
                }
            }
        }
    }
}
