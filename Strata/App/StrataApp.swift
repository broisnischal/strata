import SwiftUI

@main
enum Launcher {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            Task { exit(await SelfTest.run()) }
            dispatchMain()
        }
        StrataApp.main()
    }
}

struct StrataApp: App {
    @State private var monitor: SystemMonitor
    @State private var model: AppModel
    @AppStorage("appearance") private var appearance: Appearance = .system
    @AppStorage("showMenuBarExtra") private var showMenuBar = true

    init() {
        // Sampling starts with the app, not the window, so alerts and the
        // menu bar keep working with every window closed.
        let monitor = SystemMonitor()
        let model = AppModel()
        monitor.start()
        _monitor = State(initialValue: monitor)
        _model = State(initialValue: model)
        if let dir = Snapshot.directory {
            Task { await Snapshot.run(monitor: monitor, model: model, into: dir) }
        }
    }

    var body: some Scene {
        WindowGroup("Strata", id: "main") {
            ContentView()
                .environment(monitor)
                .environment(model)
                .frame(minWidth: 980, minHeight: 620)
                .onAppear { NSApp.appearance = appearance.nsAppearance }
                .onChange(of: appearance) { NSApp.appearance = appearance.nsAppearance }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .sidebar) {
                ForEach(Array(SidebarItem.allCases.enumerated()), id: \.element) { index, item in
                    if index < 9 {
                        Button(item.title) { model.selection = item }
                            .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    }
                }
            }
        }

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarPanel()
                .environment(monitor)
                .environment(model)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(monitor)
        }
    }
}
