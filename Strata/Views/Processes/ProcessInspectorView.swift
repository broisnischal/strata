import SwiftUI

struct ProcessInspectorView: View {
    @Environment(SystemMonitor.self) private var monitor
    let process: ProcessSample

    private enum Tab: String, CaseIterable, Identifiable {
        case info = "Info", files = "Files", sockets = "Sockets", environment = "Env", sample = "Sample"
        var id: Self { self }
    }

    @State private var tab: Tab = .info
    @State private var detail: ProcessDetail?
    @State private var adminOutput: String?
    @State private var sampleOutput: String?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(16)
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            ErrorBanner(message: $error)
            Divider()
            content.frame(maxHeight: .infinity, alignment: .top)
        }
        .task(id: process.pid) {
            detail = nil
            adminOutput = nil
            sampleOutput = nil
            let pid = process.pid
            detail = await offMain { ProcessInspector.detail(pid: pid) }
        }
    }

    private var header: some View {
        let tracked = monitor.tracking.target(for: process)
        let points = monitor.focusHistory
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: IconCache.icon(forBundle: process.bundlePath)).resizable().frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(process.name).font(.system(size: 14, weight: .semibold)).lineLimit(2).textSelection(.enabled)
                    Text("PID \(process.pid) · \(process.user) · \(process.status.rawValue)").font(Theme.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button {
                    if let tracked { monitor.tracking.untrack(tracked.id) } else { monitor.tracking.track(process) }
                } label: {
                    Image(systemName: tracked == nil ? "pin" : "pin.fill")
                }
                .buttonStyle(.borderless)
                .help(tracked == nil ? "Track this app over time" : "Stop tracking \(tracked?.title ?? "")")
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Stat(label: "CPU", value: Fmt.cpu(process.cpu) + "%")
                    TimeChart(points: points.map { TimePoint(id: $0.id, date: $0.date, value: $0.cpu) }, minimumTop: 10,
                              format: { Fmt.cpuAxis($0) }, height: 54)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Stat(label: "Memory", value: Fmt.bytes(process.memory))
                    TimeChart(points: points.map { TimePoint(id: $0.id, date: $0.date, value: $0.memory) }, minimumTop: 16_777_216, unit: 1_048_576,
                              format: { Fmt.bytes(UInt64(max($0, 0))) }, height: 54)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .info: info
        case .files: files
        case .sockets: sockets
        case .environment: environment
        case .sample: sample
        }
    }

    private var info: some View {
        Form {
            Section("Live") {
                LabeledContent("CPU", value: Fmt.cpu(process.cpu) + "%")
                LabeledContent("CPU time", value: Fmt.cpuTime(process.cpuTime))
                LabeledContent(process.limited ? "Resident memory" : "Memory footprint", value: Fmt.bytes(process.memory))
                LabeledContent("Threads", value: process.threads.map(String.init) ?? "–")
                LabeledContent("Power", value: process.power.map(Fmt.watts) ?? "–")
                LabeledContent("Wakeups/s", value: process.wakeups.map { String(format: "%.0f", $0) } ?? "–")
                LabeledContent("Disk read", value: process.diskRead.map(Fmt.rate) ?? "–")
                LabeledContent("Disk write", value: process.diskWrite.map(Fmt.rate) ?? "–")
            }
            Section("Process") {
                LabeledContent("Parent PID", value: "\(process.ppid)")
                if let start = detail?.startTime {
                    LabeledContent("Started", value: start.formatted(date: .abbreviated, time: .standard))
                }
                if let path = detail?.path ?? process.path {
                    LabeledContent("Path") {
                        Text(path).textSelection(.enabled).lineLimit(4).truncationMode(.middle)
                    }
                    .contextMenu {
                        Button("Reveal in Finder") { reveal(path) }
                        Button("Copy Path") { copyToPasteboard(path) }
                    }
                }
                if let cwd = detail?.workingDirectory, !cwd.isEmpty {
                    LabeledContent("Working dir") { Text(cwd).textSelection(.enabled).lineLimit(2).truncationMode(.middle) }
                }
            }
            if let args = detail?.arguments, !args.isEmpty {
                Section("Arguments") {
                    ForEach(Array(args.enumerated()), id: \.offset) { _, arg in
                        Text(arg).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var files: some View {
        if let detail, detail.accessible || !detail.files.isEmpty {
            List(detail.files) { file in
                HStack(alignment: .firstTextBaseline) {
                    Text("\(file.id)").monospacedDigit().foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                    Text(file.path).font(.system(.caption, design: .monospaced)).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                }
                .revealInFinderMenu(file.kind == "File" ? file.path : nil)
            }
            .overlay { if detail.files.isEmpty { ContentUnavailableView("No Open Files", systemImage: "doc") } }
        } else if detail == nil {
            LoadingView(text: "Reading descriptors…")
        } else {
            adminFallback
        }
    }

    @ViewBuilder
    private var sockets: some View {
        if let detail, detail.accessible || !detail.sockets.isEmpty {
            Table(detail.sockets) {
                TableColumn("Proto", value: \.proto).width(44)
                TableColumn("Local") { Text($0.local).textSelection(.enabled) }
                TableColumn("Remote") { Text($0.remote).textSelection(.enabled) }
                TableColumn("State", value: \.state).width(80)
            }
            .font(.system(.caption, design: .monospaced))
            .overlay { if detail.sockets.isEmpty { ContentUnavailableView("No Sockets", systemImage: "network.slash") } }
        } else if detail == nil {
            LoadingView(text: "Reading sockets…")
        } else {
            adminFallback
        }
    }

    @ViewBuilder
    private var environment: some View {
        if let env = detail?.environment, !env.isEmpty {
            List(Array(env.enumerated()), id: \.offset) { _, entry in
                let parts = entry.split(separator: "=", maxSplits: 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(parts.first.map(String.init) ?? entry).font(.caption.weight(.semibold))
                    Text(parts.count > 1 ? String(parts[1]) : "").font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                }
            }
        } else if detail == nil {
            LoadingView(text: "Reading environment…")
        } else {
            ContentUnavailableView("Not Available", systemImage: "lock", description: Text("macOS only exposes the environment of your own processes."))
        }
    }

    private var sample: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(busy ? "Sampling…" : "Sample for 3 Seconds") { Task { await runSample() } }.disabled(busy)
                Spacer()
                if let sampleOutput { Button("Copy") { copyToPasteboard(sampleOutput) } }
            }
            .padding([.horizontal, .top], 12)
            outputView(sampleOutput, placeholder: "Captures call stacks of every thread using /usr/bin/sample.")
        }
    }

    private var adminFallback: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let adminOutput {
                outputView(adminOutput, placeholder: "")
            } else {
                ContentUnavailableView {
                    Label("Needs Administrator Access", systemImage: "lock.shield")
                } description: {
                    Text("\(process.name) belongs to \(process.user). Run lsof as root to list its files and sockets.")
                } actions: {
                    Button(busy ? "Running…" : "Run lsof as Administrator") { Task { await runAdminLsof() } }.disabled(busy)
                }
            }
        }
    }

    @ViewBuilder
    private func outputView(_ text: String?, placeholder: String) -> some View {
        if let text {
            TextLog(text: text)
        } else {
            Text(placeholder)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)
        }
    }

    private func runSample() async {
        busy = true
        defer { busy = false }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("strata-\(process.pid)-\(UUID().uuidString).sample.txt").path
        do {
            let result = try await Shell.run("/usr/bin/sample", ["\(process.pid)", "3", "-mayDie", "-file", file])
            let output = (try? String(contentsOfFile: file, encoding: .utf8)) ?? (result.stdout + result.stderr)
            try? FileManager.default.removeItem(atPath: file)
            if !result.succeeded && output.isEmpty {
                error = result.stderr.isEmpty ? "sample failed (status \(result.status))." : result.stderr
            }
            sampleOutput = output
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func runAdminLsof() async {
        busy = true
        defer { busy = false }
        do {
            adminOutput = try await Shell.runAsAdmin("/usr/sbin/lsof -n -P -p \(process.pid)").stdout
        } catch ShellError.cancelled {
        } catch {
            self.error = error.localizedDescription
        }
    }
}
