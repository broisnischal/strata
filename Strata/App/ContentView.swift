import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(SystemMonitor.self) private var monitor

    private let sections: [(String?, [SidebarItem])] = [
        (nil, [.overview, .processes, .tracked, .alerts]),
        ("Drivers", [.kexts, .systemExtensions, .devices]),
        ("Files", [.volumes, .diskUsage]),
        ("Startup", [.launchItems, .backgroundItems]),
    ]

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(sections, id: \.1) { title, items in
                    Section {
                        ForEach(items) { item in
                            Label(item.title, systemImage: item.icon)
                                .badge(item == .alerts ? monitor.alerts.unread : 0)
                                .tag(item)
                        }
                    } header: {
                        if let title { Text(title) }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .bottom) { SidebarStats() }
        } detail: {
            PageView(item: model.selection ?? .overview)
        }
        .onReceive(NotificationCenter.default.publisher(for: NotificationDelegate.openAlerts)) { _ in
            model.selection = .alerts
        }
    }
}

/// The page for a sidebar item.
struct PageView: View {
    let item: SidebarItem

    var body: some View {
        switch item {
        case .overview: OverviewView()
        case .processes: ProcessesView()
        case .tracked: TrackedView()
        case .alerts: AlertsView()
        case .kexts: KextsView()
        case .systemExtensions: SystemExtensionsView()
        case .devices: DevicesView()
        case .volumes: VolumesView()
        case .diskUsage: DiskUsageView()
        case .launchItems: LaunchItemsView()
        case .backgroundItems: BackgroundItemsView()
        }
    }
}

private struct SidebarStats: View {
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        let snap = monitor.snapshot
        VStack(spacing: 10) {
            row("CPU", Fmt.percent(snap.cpu), monitor.recent(\.cpu), top: 1)
            row("Memory", Fmt.bytes(snap.memory.used), monitor.recent(\.memoryUsed), top: 1)
            HStack {
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Settings")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func row(_ label: String, _ value: String, _ values: [Double], top: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text(value).monospacedDigit()
            }
            .font(Theme.caption)
            Sparkline(values: values, top: top, height: 16)
        }
    }
}
