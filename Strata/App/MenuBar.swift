import SwiftUI

/// The menu bar item: CPU and memory at a glance, and a mark when something
/// is alerting.
struct MenuBarLabel: View {
    let monitor: SystemMonitor
    @AppStorage("menuBarShowsCPU") private var showsCPU = true
    @AppStorage("menuBarShowsMemory") private var showsMemory = true

    var body: some View {
        let snap = monitor.snapshot
        let memory = Double(snap.memory.used) / Double(max(snap.memory.total, 1))
        let alerting = !monitor.alerts.active.isEmpty
        let parts = [
            showsCPU ? "\(Int((snap.cpu * 100).rounded()))%" : nil,
            showsMemory ? "\(Int((memory * 100).rounded()))%" : nil,
        ].compactMap { $0 }
        HStack(spacing: 4) {
            Image(systemName: alerting ? "exclamationmark.triangle.fill" : "square.3.layers.3d")
            if !parts.isEmpty { Text(parts.joined(separator: " · ")).monospacedDigit() }
        }
    }
}

struct MenuBarPanel: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let snap = monitor.snapshot
        let m = snap.memory
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("Strata").font(.system(size: 13, weight: .semibold))
                Spacer()
                StatusLabel(severity: Severity(pressureLevel: m.pressureLevel), text: "Memory \(m.pressureName.lowercased())")
                Button(action: settings) {
                    Image(systemName: "gearshape").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Settings, including what shows in the menu bar")
            }
            VStack(spacing: 10) {
                metric("CPU", Fmt.percent(snap.cpu), monitor.recent(\.cpu), top: 1)
                metric("Memory", "\(Fmt.bytes(m.used)) of \(Fmt.bytes(m.total))", monitor.recent(\.memoryUsed), top: 1)
                if let gpu = snap.gpu { metric("GPU", Fmt.percent(gpu), monitor.recent(\.gpu), top: 1) }
                metric("Power", Fmt.watts(snap.systemPower ?? monitor.processPower),
                       monitor.recent(snap.systemPower != nil ? \.power : \.processPower), top: nil)
                HStack {
                    Text("Network").foregroundStyle(.secondary)
                    Spacer()
                    Text("↓ \(Fmt.rate(snap.netIn))  ↑ \(Fmt.rate(snap.netOut))").monospacedDigit()
                }
                .font(.system(size: 12))
            }
            let alerts = monitor.alerts.activeSorted
            if !alerts.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(alerts.prefix(3), id: \.key) { e in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: e.severity.icon).foregroundStyle(e.severity.color)
                            Text(e.title).lineLimit(2)
                        }
                        .font(.system(size: 12))
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Top processes").font(Theme.caption).foregroundStyle(.secondary)
                ForEach(monitor.topProcesses.prefix(5)) { p in
                    ProcessLine(process: p, tracked: monitor.tracking.target(for: p) != nil, showsBar: false)
                }
            }
            Divider()
            HStack(spacing: 14) {
                TextButton("Open Strata") { open(.overview) }
                Spacer()
                TextButton("Alerts") { open(.alerts) }
                TextButton("Settings", action: settings)
                TextButton("Quit") { NSApp.terminate(nil) }
            }
            .font(.system(size: 12))
        }
        .padding(16)
        .frame(width: 320)
    }

    private func metric(_ label: String, _ value: String, _ values: [Double], top: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text(value).monospacedDigit()
            }
            .font(.system(size: 12))
            Sparkline(values: values, top: top, height: 20)
        }
    }

    private func settings() {
        NSApp.activate()
        openSettings()
    }

    private func open(_ page: SidebarItem) {
        model.selection = page
        openWindow(id: "main")
        NSApp.activate()
    }
}
