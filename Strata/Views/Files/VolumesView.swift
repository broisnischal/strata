import SwiftUI

struct VolumesView: View {
    @Environment(AppModel.self) private var model
    @State private var volumes: [VolumeInfo]?
    @State private var usage: VolumeUsage?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            ErrorBanner(message: $error)
            if let volumes {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 16, alignment: .top)], spacing: 16) {
                        ForEach(volumes) { volume in
                            VolumeCard(volume: volume,
                                       onScan: { model.scan(volume.url.path) },
                                       onWho: { usage = VolumeUsage(volume: volume) },
                                       onEject: { eject(volume) })
                        }
                    }
                    .padding(20)
                }
            } else {
                LoadingView(text: "Reading volumes…")
            }
        }
        .navigationTitle("Volumes")
        .toolbar {
            Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        }
        .task { await load() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in Task { await load() } }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in Task { await load() } }
        .sheet(item: $usage) { VolumeUsageSheet(usage: $0) }
    }

    private func load() async {
        volumes = await offMain { VolumeCatalog.volumes() }
    }

    private func eject(_ volume: VolumeInfo) {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volume.url)
        } catch {
            self.error = "Couldn't eject \(volume.name): \(error.localizedDescription). Use “Who's Using” to find processes holding it open."
        }
    }
}

private struct VolumeCard: View {
    let volume: VolumeInfo
    let onScan: () -> Void
    let onWho: () -> Void
    let onEject: () -> Void

    var body: some View {
        Card(volume.name, icon: volume.isInternal ? "internaldrive" : "externaldrive") {
            HStack(spacing: 4) {
                if volume.isEncrypted { Badge(text: "Encrypted", tint: .green) }
                Badge(text: volume.format)
            }
        } content: {
            Text(volume.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            BigValue(value: Fmt.fileBytes(volume.available), caption: "free of \(Fmt.fileBytes(volume.capacity))")
            SegmentedBar(segments: [
                .init(label: "Used", value: Double(volume.used), color: volume.usedFraction > 0.9 ? .red : .blue),
                .init(label: "Purgeable", value: Double(volume.purgeable), color: .blue.opacity(0.35)),
            ], total: Double(volume.capacity))
            HStack(spacing: 16) {
                LegendItem(color: .blue, label: "Used", value: Fmt.fileBytes(volume.used))
                LegendItem(color: .blue.opacity(0.35), label: "Purgeable", value: Fmt.fileBytes(volume.purgeable))
            }
            HStack {
                Button("Scan Usage", systemImage: "square.grid.3x3.topleft.filled", action: onScan)
                if !volume.isRoot { Button("Who's Using", systemImage: "person.2", action: onWho) }
                Spacer()
                Button("Reveal", systemImage: "folder") { reveal(volume.url.path) }.labelStyle(.iconOnly).help("Reveal in Finder")
                if volume.isEjectable || volume.isRemovable {
                    Button("Eject", systemImage: "eject", action: onEject).labelStyle(.iconOnly).help("Eject")
                }
            }
            .controlSize(.small)
        }
    }
}

struct VolumeUsage: Identifiable {
    let volume: VolumeInfo
    var id: URL { volume.url }
}

private struct VolumeUsageSheet: View {
    let usage: VolumeUsage
    @Environment(\.dismiss) private var dismiss
    @State private var result: (users: [ProcessInspector.PathUser], skipped: Int)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Processes using “\(usage.volume.name)”").font(.headline)
            if let result {
                let grouped = Dictionary(grouping: result.users, by: \.pid).sorted { $0.value.count > $1.value.count }
                List(grouped, id: \.key) { pid, files in
                    DisclosureGroup {
                        ForEach(files) { Text($0.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    } label: {
                        HStack {
                            Text(files.first?.name ?? "\(pid)")
                            Text("PID \(pid)").foregroundStyle(.secondary)
                            Spacer()
                            Text("\(files.count) open").foregroundStyle(.secondary)
                        }
                    }
                }
                .overlay { if result.users.isEmpty { ContentUnavailableView("No Open Files", systemImage: "checkmark.circle") } }
                Text("\(result.skipped) processes owned by other users weren't checked.").font(.caption).foregroundStyle(.secondary)
            } else {
                LoadingView(text: "Checking open files…")
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 440)
        .task {
            let path = usage.volume.url.path
            result = await offMain { ProcessInspector.users(ofPathPrefix: path) }
        }
    }
}
