import SwiftUI

enum ProcessFilter: String, CaseIterable, Identifiable {
    case all = "All", mine = "My Processes", others = "Other Users", apps = "Apps", tracked = "Tracked"
    var id: Self { self }
}

struct ProcessesView: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var filter: ProcessFilter = .all
    @State private var asTree = false
    @State private var sortOrder = [KeyPathComparator(\ProcessSample.cpu, order: .reverse)]
    @State private var selection: Int32?
    @State private var showInspector = true
    @State private var killRequest: KillRequest?
    @State private var error: String?
    /// Rows as shown: values from the latest sample, positions held between reorders.
    @State private var rows: [ProcessSample] = []
    @State private var order = StableOrder()
    @State private var pointing = false

    private let myUID = getuid()

    var body: some View {
        VStack(spacing: 0) {
            ErrorBanner(message: $error)
            table
            Divider()
            footer
        }
        .background(Theme.canvas)
        .navigationTitle("Processes")
        .searchable(text: $search, placement: .toolbar, prompt: "Name, PID, or user")
        .toolbar { toolbar }
        .inspector(isPresented: $showInspector) {
            Group {
                if let process = selectedProcess {
                    ProcessInspectorView(process: process)
                } else {
                    ContentUnavailableView("No Selection", systemImage: "cursorarrow.click", description: Text("Select a process to see its details."))
                }
            }
            .inspectorColumnWidth(min: 300, ideal: 360, max: 560)
        }
        .confirmationDialog(killRequest?.title ?? "", isPresented: Binding(get: { killRequest != nil }, set: { if !$0 { killRequest = nil } }), presenting: killRequest) { request in
            Button(request.force ? "Force Quit" : "Quit", role: .destructive) { Task { await kill(request) } }
        } message: { request in
            Text(request.message)
        }
        .onAppear {
            if let pid = model.revealPID { select(pid) }
            refreshRows(force: true)
        }
        .onChange(of: model.revealPID) { if let pid = model.revealPID { select(pid) } }
        .onChange(of: monitor.sequence) { refreshRows(force: false) }
        .onChange(of: search) { refreshRows(force: true) }
        .onChange(of: filter) { refreshRows(force: true) }
        .onChange(of: asTree) { refreshRows(force: true) }
        .onChange(of: sortOrder) { refreshRows(force: true) }
        .onChange(of: selection) { monitor.focusPID = selection }
        .onDisappear { monitor.focusPID = nil }
    }

    private var table: some View {
        Table(rows, children: \.children, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Process", value: \.name) { p in
                HStack(spacing: 6) {
                    Image(nsImage: IconCache.icon(forBundle: p.bundlePath)).resizable().frame(width: 16, height: 16)
                    Text(p.name).lineLimit(1).truncationMode(.middle)
                    if monitor.tracking.target(for: p) != nil {
                        Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.secondary).help("Tracked")
                    }
                    if p.limited {
                        Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.tertiary)
                            .help("Owned by \(p.user): CPU and memory come from ps; other details need admin.")
                    }
                }
            }
            .width(min: 180, ideal: 250)
            TableColumn("% CPU", value: \.cpu) { p in
                Text(Fmt.cpu(p.cpu)).monospacedDigit().foregroundStyle(p.cpu >= 0.05 ? .primary : .tertiary)
            }
            .width(60)
            TableColumn("Memory", value: \.memory) { Text(Fmt.bytes($0.memory)).monospacedDigit() }.width(78)
            TableColumn("Power", value: \.sortPower) { p in
                Text(p.power.map(Fmt.watts) ?? "–").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(68)
            TableColumn("Threads", value: \.sortThreads) { p in
                Text(p.threads.map(String.init) ?? "–").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(54)
            TableColumn("CPU Time", value: \.cpuTime) { Text(Fmt.cpuTime($0.cpuTime)).monospacedDigit().foregroundStyle(.secondary) }.width(74)
            TableColumn("Disk Read", value: \.sortDiskRead) { p in
                Text(p.diskRead.map(Fmt.rate) ?? "–").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(76)
            TableColumn("Disk Write", value: \.sortDiskWrite) { p in
                Text(p.diskWrite.map(Fmt.rate) ?? "–").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(76)
            TableColumn("PID", value: \.pid) { Text(verbatim: "\($0.pid)").monospacedDigit().foregroundStyle(.secondary) }.width(54)
            TableColumn("User", value: \.user) { Text($0.user).foregroundStyle(.secondary) }.width(min: 56, ideal: 76)
        }
        .tableStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
        .transaction { $0.animation = nil }
        .onHover { pointing = $0 }
        .contextMenu(forSelectionType: Int32.self) { ids in
            if let pid = ids.first, let p = monitor.processes.first(where: { $0.pid == pid }) {
                trackMenu(for: p)
                Divider()
                Button("Quit \(p.name)") { killRequest = KillRequest(process: p, force: false) }
                Button("Force Quit \(p.name)") { killRequest = KillRequest(process: p, force: true) }
                Divider()
                if let path = p.path {
                    Button("Reveal in Finder") { reveal(path) }
                    Button("Copy Path") { copyToPasteboard(path) }
                }
                Button("Copy PID") { copyToPasteboard("\(p.pid)") }
            }
        } primaryAction: { _ in
            showInspector = true
        }
    }

    @ViewBuilder
    private func trackMenu(for p: ProcessSample) -> some View {
        if let t = monitor.tracking.target(for: p) {
            Button("Show in Tracked") { model.selection = .tracked }
            Button("Stop Tracking \(t.title)") { monitor.tracking.untrack(t.id) }
        } else if let app = p.appPath {
            Button("Track \((app as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: ""))") { monitor.tracking.track(p) }
        } else {
            Button("Track \(p.name)") { monitor.tracking.track(p) }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("\(monitor.processes.count) processes · \(monitor.processes.filter(\.limited).count) limited")
            Spacer()
            Label(pointing ? "Order held while the pointer is on the list" : "Reorders every \(Int(monitor.reorderInterval)) s",
                  systemImage: pointing ? "pause.circle" : "arrow.up.arrow.down")
            Spacer()
            Text("CPU \(Fmt.percent(monitor.snapshot.cpu)) · Memory \(Fmt.bytes(monitor.snapshot.memory.used)) · Power \(Fmt.watts(monitor.processPower))")
        }
        .font(Theme.caption).foregroundStyle(.secondary).monospacedDigit()
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Picker("Filter", selection: $filter) {
                ForEach(ProcessFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
        }
        ToolbarItem {
            Toggle(isOn: $asTree) { Label("Tree", systemImage: "list.bullet.indent") }
                .help("Show processes as a parent/child tree")
        }
        ToolbarItemGroup {
            Button {
                if let p = selectedProcess { toggleTracking(p) }
            } label: {
                Label("Track", systemImage: selectedTracked ? "pin.slash" : "pin")
            }
            .disabled(selectedProcess == nil)
            .help(selectedTracked ? "Stop tracking the selected app" : "Track the selected app or process over time")
            Button { requestKill(force: false) } label: { Label("Quit", systemImage: "xmark.octagon") }
                .disabled(selectedProcess == nil)
                .help("Quit the selected process (SIGTERM)")
            Button { requestKill(force: true) } label: { Label("Force Quit", systemImage: "bolt.slash") }
                .disabled(selectedProcess == nil)
                .help("Force quit the selected process (SIGKILL)")
            Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
        }
    }

    private var selectedProcess: ProcessSample? {
        guard let selection else { return nil }
        return monitor.processes.first { $0.pid == selection }
    }

    private var selectedTracked: Bool {
        selectedProcess.map { monitor.tracking.target(for: $0) != nil } ?? false
    }

    private func toggleTracking(_ p: ProcessSample) {
        if let t = monitor.tracking.target(for: p) { monitor.tracking.untrack(t.id) } else { monitor.tracking.track(p) }
    }

    private func select(_ pid: Int32) {
        filter = .all
        search = ""
        selection = pid
        showInspector = true
        model.revealPID = nil
    }

    /// Positions move only at a reorder (every few seconds, never while the
    /// pointer is on the list) or when the sort, filter or search changes.
    private func refreshRows(force: Bool) {
        var list = monitor.processes
        switch filter {
        case .all: break
        case .mine: list = list.filter { $0.uid == myUID }
        case .others: list = list.filter { $0.uid != myUID }
        case .apps: list = list.filter { monitor.appPIDs.contains($0.pid) }
        case .tracked: list = list.filter { monitor.tracking.target(for: $0) != nil }
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            list = list.filter {
                $0.name.localizedCaseInsensitiveContains(query) || "\($0.pid)" == query || $0.user.localizedCaseInsensitiveContains(query)
                    || ($0.path?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }
        let comparators = sortOrder
        let ordered = order.order(list, by: { a, b in
            for c in comparators {
                switch c.compare(a, b) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: continue
                }
            }
            return a.pid < b.pid
        }, every: monitor.reorderInterval, frozen: pointing, force: force)
        rows = asTree && query.isEmpty && filter == .all ? ProcessTree.build(ordered) : ordered
    }

    private func requestKill(force: Bool) {
        guard let p = selectedProcess else { return }
        killRequest = KillRequest(process: p, force: force)
    }

    private func kill(_ request: KillRequest) async {
        do {
            try await ProcessControl.terminate(request.process, force: request.force)
        } catch ShellError.cancelled {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension ProcessSample {
    var sortThreads: Int { threads ?? -1 }
    var sortPower: Double { power ?? -1 }
    var sortDiskRead: Double { diskRead ?? -1 }
    var sortDiskWrite: Double { diskWrite ?? -1 }
}

struct KillRequest: Identifiable {
    let process: ProcessSample
    let force: Bool
    var id: Int32 { process.pid }
    var title: String { "\(force ? "Force quit" : "Quit") “\(process.name)”?" }
    var message: String {
        var text = force ? "The process is killed immediately and unsaved changes are lost." : "The process is asked to quit."
        if process.uid != getuid() { text += " It belongs to \(process.user), so you'll be asked for an administrator password." }
        return text
    }
}

enum ProcessTree {
    /// Parents and children, siblings kept in the order given.
    static func build(_ ordered: [ProcessSample]) -> [ProcessSample] {
        let pids = Set(ordered.map(\.pid))
        var byParent: [Int32: [ProcessSample]] = [:]
        for p in ordered where p.ppid != p.pid && pids.contains(p.ppid) { byParent[p.ppid, default: []].append(p) }
        func attach(_ p: ProcessSample, depth: Int) -> ProcessSample {
            var node = p
            if depth < 64, let kids = byParent[p.pid], !kids.isEmpty {
                node.children = kids.map { attach($0, depth: depth + 1) }
            }
            return node
        }
        return ordered.filter { $0.ppid == $0.pid || !pids.contains($0.ppid) }.map { attach($0, depth: 0) }
    }
}

enum ProcessControl {
    @MainActor
    static func terminate(_ p: ProcessSample, force: Bool) async throws {
        if let app = NSRunningApplication(processIdentifier: p.pid), app.activationPolicy != .prohibited {
            if force ? app.forceTerminate() : app.terminate() { return }
        }
        if Darwin.kill(p.pid, force ? SIGKILL : SIGTERM) == 0 { return }
        guard errno == EPERM else { throw ShellError.failed(String(cString: strerror(errno))) }
        _ = try await Shell.runAsAdmin("/bin/kill -\(force ? "KILL" : "TERM") \(p.pid)")
    }
}
