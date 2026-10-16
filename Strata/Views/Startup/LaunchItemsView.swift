import SwiftUI

struct LaunchItemsView: View {
    @AppStorage("showAppleLaunchItems") private var showApple = false
    @State private var items: [LaunchItem]?
    @State private var search = ""
    @State private var scope: LaunchScope?
    @State private var selection: LaunchItem.ID?
    @State private var sortOrder = [KeyPathComparator(\LaunchItem.label)]
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            ErrorBanner(message: $error)
            if let items {
                let rows = filtered(items)
                Table(rows, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Label", value: \.label) { item in
                        Text(item.label).lineLimit(1).truncationMode(.middle).foregroundStyle(item.isDisabled ? .secondary : .primary)
                    }
                    .width(min: 220, ideal: 300)
                    TableColumn("Kind", value: \.scope.rawValue) { Text($0.scope.rawValue) }.width(min: 80, ideal: 100)
                    TableColumn("Status", value: \.statusText) { item in
                        HStack(spacing: 6) {
                            StatusDot(color: item.pid != nil ? .green : item.isDisabled ? .red : item.loaded ? .yellow : .secondary)
                            Text(item.statusText)
                        }
                    }
                    .width(min: 90, ideal: 120)
                    TableColumn("Runs", value: \.trigger) { Text($0.trigger).foregroundStyle(.secondary) }.width(min: 90, ideal: 140)
                    TableColumn("Program") { item in
                        Text(item.program ?? "–").lineLimit(1).truncationMode(.head).foregroundStyle(.secondary).help(item.arguments.joined(separator: " "))
                    }
                    .width(min: 140, ideal: 240)
                    TableColumn("Signed By") { item in
                        Text(item.signer ?? (item.scope.isApple ? "Apple" : "…")).lineLimit(1)
                            .foregroundStyle(item.signer == "Unsigned" || item.signer == "Missing" ? .red : .secondary)
                    }
                }
                .contextMenu(forSelectionType: LaunchItem.ID.self) { ids in
                    if let id = ids.first, let item = items.first(where: { $0.id == id }) { menu(for: item) }
                }
                .safeAreaInset(edge: .bottom) {
                    footer("\(rows.count) shown · \(items.filter { $0.pid != nil }.count) running · \(items.filter(\.isDisabled).count) disabled")
                }
            } else {
                LoadingView(text: "Reading launchd jobs…")
            }
        }
        .navigationTitle("Launch Items")
        .searchable(text: $search, placement: .toolbar)
        .toolbar {
            Picker("Kind", selection: $scope) {
                Text("All Kinds").tag(LaunchScope?.none)
                ForEach(LaunchScope.allCases.filter { showApple || !$0.isApple }, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
            }
            .pickerStyle(.menu)
            Toggle(isOn: $showApple) { Label("Apple", systemImage: "apple.logo") }.help("Include Apple agents and daemons")
            Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(busy)
        }
        .task(id: showApple) { await load() }
    }

    @ViewBuilder
    private func menu(for item: LaunchItem) -> some View {
        if !item.scope.isApple {
            if item.isDisabled {
                Button("Enable") { act(.enable, item) }
            } else {
                Button("Disable") { act(.disable, item) }
            }
            if item.loaded {
                Button("Unload (bootout)") { act(.unload, item) }
            } else {
                Button("Load (bootstrap)") { act(.load, item) }
            }
            Divider()
        }
        Button("Reveal Plist in Finder") { reveal(item.plistPath) }
        Button("Open Plist") { NSWorkspace.shared.open(URL(fileURLWithPath: item.plistPath)) }
        if let program = item.program, program.hasPrefix("/") { Button("Reveal Program in Finder") { reveal(program) } }
        Button("Copy Label") { copyToPasteboard(item.label) }
    }

    private func filtered(_ list: [LaunchItem]) -> [LaunchItem] {
        list.filter { item in
            (scope == nil || item.scope == scope)
                && (search.isEmpty || item.label.localizedCaseInsensitiveContains(search) || (item.program?.localizedCaseInsensitiveContains(search) ?? false))
        }
        .sorted(using: sortOrder)
    }

    private func act(_ action: LaunchCatalog.Action, _ item: LaunchItem) {
        Task {
            busy = true
            defer { busy = false }
            do {
                try await LaunchCatalog.perform(action, on: item)
                await load()
            } catch ShellError.cancelled {
            } catch {
                self.error = "\(action.rawValue.capitalized) \(item.label) failed: \(error.localizedDescription)"
            }
        }
    }

    private func load() async {
        busy = true
        defer { busy = false }
        let include = showApple
        var loaded = await LaunchCatalog.items(includeApple: include)
        items = loaded
        let targets = loaded.enumerated().filter { !$0.element.scope.isApple && ($0.element.program?.hasPrefix("/") ?? false) }
            .map { ($0.offset, $0.element.program!) }
        let signers = await offMain { targets.map { ($0.0, CodeSigning.signer(of: $0.1)) } }
        for (index, signer) in signers { loaded[index].signer = signer }
        items = loaded
    }
}
