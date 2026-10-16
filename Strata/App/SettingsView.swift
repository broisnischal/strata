import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(SystemMonitor.self) private var monitor
    @AppStorage("appearance") private var appearance: Appearance = .system
    @AppStorage("showMenuBarExtra") private var showMenuBar = true
    @AppStorage("menuBarShowsCPU") private var menuBarCPU = true
    @AppStorage("menuBarShowsMemory") private var menuBarMemory = true
    @AppStorage("showAppleLaunchItems") private var showApple = false
    @AppStorage("showAppleKexts") private var showAppleKexts = true
    @State private var login = LoginItem()

    var body: some View {
        @Bindable var monitor = monitor
        Form {
            Section("General") {
                Toggle("Open Strata at login", isOn: Binding(get: { login.isOn }, set: { login.set($0) }))
                if login.needsApproval {
                    HStack {
                        Text("Allow Strata under Login Items in System Settings.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let error = login.error {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Look") {
                Picker("Appearance", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section {
                Toggle("Show Strata in the menu bar", isOn: $showMenuBar)
                Toggle("CPU usage", isOn: $menuBarCPU).disabled(!showMenuBar)
                Toggle("Memory usage", isOn: $menuBarMemory).disabled(!showMenuBar)
            } header: {
                Text("Menu Bar")
            } footer: {
                Text("With both off, the menu bar shows just the icon. Alerts keep working when Strata isn't in the menu bar; open Settings again from the app with ⌘,.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Sampling") {
                Picker("Refresh every", selection: $monitor.interval) {
                    ForEach(SystemMonitor.intervals, id: \.self) { value in
                        Text(value < 1 ? "\(value.formatted()) seconds" : value == 1 ? "1 second" : "\(Int(value)) seconds").tag(value)
                    }
                }
                Picker("Reorder process lists every", selection: $monitor.reorderInterval) {
                    ForEach(SystemMonitor.reorderIntervals, id: \.self) { Text("\(Int($0)) seconds").tag($0) }
                }
                Text("Values update with every sample; rows change places only this often, and never while the pointer is on the list.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Lists") {
                Toggle("Show Apple launch agents and daemons", isOn: $showApple)
                Toggle("Show Apple kernel extensions", isOn: $showAppleKexts)
            }
        }
        .formStyle(.grouped)
        .onAppear { login.refresh() }
        .frame(width: 460)
        .fixedSize()
    }
}
