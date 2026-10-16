import SwiftUI

struct DiskUsageView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: FileNode.ID?
    @State private var hovered: FileNode.ID?
    @State private var pendingTrash: FileNode?
    @State private var error: String?

    private var usage: DiskUsageModel { model.diskUsage }

    var body: some View {
        VStack(spacing: 0) {
            ErrorBanner(message: $error)
            if usage.isScanning {
                scanning
            } else if let current = usage.current {
                breadcrumb.padding(.horizontal, 12).padding(.vertical, 8)
                Divider()
                HSplitView {
                    TreemapView(node: current, selection: $selection, hovered: $hovered) { usage.open($0) }
                        .frame(minWidth: 320)
                    list(current).frame(minWidth: 300, idealWidth: 380)
                }
                Divider()
                footer(current)
            } else {
                ContentUnavailableView {
                    Label("Disk Usage", systemImage: "square.grid.3x3.topleft.filled")
                } description: {
                    Text("Scan a folder or volume to see what takes up space.")
                } actions: {
                    Button("Scan Home Folder") { usage.start(path: NSHomeDirectory()) }.buttonStyle(.borderedProminent)
                    Button("Choose Folder…", action: choose)
                }
            }
        }
        .navigationTitle("Disk Usage")
        .navigationSubtitle(usage.path)
        .toolbar {
            Button("Choose Folder…", systemImage: "folder", action: choose)
            if usage.isScanning {
                Button("Stop", systemImage: "stop.fill") { usage.cancel() }
            } else {
                Button("Rescan", systemImage: "arrow.clockwise") { usage.start() }
            }
        }
        .confirmationDialog("Move “\(pendingTrash?.name ?? "")” to the Trash?", isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }), presenting: pendingTrash) { node in
            Button("Move to Trash", role: .destructive) {
                do { try usage.trash(node) } catch { self.error = error.localizedDescription }
            }
        } message: { node in
            Text("\(Fmt.fileBytes(node.size)) will be moved to the Trash.")
        }
    }

    private var scanning: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Scanning \(usage.path)").font(.headline)
            Text("\(usage.progress.files.formatted()) files · \(Fmt.fileBytes(usage.progress.bytes))").monospacedDigit()
            Text(usage.progress.current).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).frame(maxWidth: 520)
            Button("Stop") { usage.cancel() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(usage.stack.enumerated()), id: \.element.id) { index, node in
                    if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                    Button { usage.pop(to: node) } label: {
                        Text(node.name).fontWeight(index == usage.stack.count - 1 ? .semibold : .regular)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(index == usage.stack.count - 1 ? .primary : .secondary)
                }
            }
        }
    }

    private func list(_ current: FileNode) -> some View {
        List(current.children, selection: $selection) { node in
            HStack(spacing: 8) {
                Image(systemName: node.isAggregate ? "doc.on.doc" : node.isDirectory ? "folder.fill" : "doc")
                    .foregroundStyle(node.isDirectory ? Color.accentColor : .secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(node.name).lineLimit(1).truncationMode(.middle)
                        if node.unreadable { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.tertiary).help("Couldn't read this folder") }
                        Spacer()
                        Text(Fmt.fileBytes(node.size)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    SizeBar(fraction: current.size > 0 ? Double(node.size) / Double(current.size) : 0,
                            tint: node.isDirectory ? .accentColor : .secondary)
                }
            }
            .padding(.vertical, 2)
            .background(hovered == node.id ? Color.accentColor.opacity(0.08) : .clear)
            .contentShape(.rect)
            .onTapGesture(count: 2) { usage.open(node) }
            .contextMenu {
                if node.isDirectory { Button("Open") { usage.open(node) } }
                Button("Reveal in Finder") { usage.reveal(node) }
                if !node.isAggregate {
                    Button("Copy Path") { copyToPasteboard(node.path) }
                    Divider()
                    Button("Move to Trash…", role: .destructive) { pendingTrash = node }
                }
            }
        }
    }

    private func footer(_ current: FileNode) -> some View {
        HStack {
            Text("\(Fmt.fileBytes(current.size)) · \(current.fileCount.formatted()) files")
            if usage.progress.unreadable > 0 {
                Text("· \(usage.progress.unreadable) folders unreadable (grant Full Disk Access in System Settings to include them)")
            }
            Spacer()
            if let duration = usage.duration {
                Text("Scanned in \(duration.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow, maximumUnitCount: 2)))")
            }
        }
        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: usage.path)
        panel.prompt = "Scan"
        if panel.runModal() == .OK, let url = panel.url { usage.start(path: url.path) }
    }
}

private struct TreemapView: View {
    let node: FileNode
    @Binding var selection: FileNode.ID?
    @Binding var hovered: FileNode.ID?
    let onOpen: (FileNode) -> Void

    /// One hue for folders, neutral for files: size is the story, not colour.
    private func fill(_ item: FileNode) -> Color {
        item.isAggregate ? Theme.neutral : item.isDirectory ? Theme.series1 : Theme.neutral
    }

    var body: some View {
        GeometryReader { geo in
            let items = Array(node.children.prefix(300).filter { $0.size > 0 })
            let rects = Treemap.layout(items.map { Double($0.size) }, in: CGRect(origin: .zero, size: geo.size).insetBy(dx: 4, dy: 4))
            // Views, not a Canvas: a Canvas would put the whole window on GPU drawables.
            ZStack(alignment: .topLeading) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let rect = rects[index].insetBy(dx: 1, dy: 1)
                    if rect.width > 0.5, rect.height > 0.5 {
                        let emphasized = item.id == selection || item.id == hovered
                        let shape = RoundedRectangle(cornerRadius: min(4, rect.width / 4, rect.height / 4), style: .continuous)
                        shape
                            .fill(fill(item).opacity(emphasized ? 0.95 : item.isDirectory ? 0.6 : 0.5))
                            .overlay { if item.id == selection { shape.strokeBorder(.primary, lineWidth: 2) } }
                            .overlay(alignment: .topLeading) {
                                if rect.width > 60, rect.height > 30 {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.name).font(.caption.weight(.semibold)).lineLimit(1)
                                        Text(Fmt.fileBytes(item.size)).font(.caption2).monospacedDigit()
                                    }
                                    .foregroundStyle(item.isDirectory ? .white : .primary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 4)
                                }
                            }
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(.rect)
            .onContinuousHover { phase in
                if case .active(let point) = phase {
                    hovered = rects.firstIndex { $0.contains(point) }.map { items[$0].id }
                } else {
                    hovered = nil
                }
            }
            .gesture(SpatialTapGesture(count: 2).onEnded { value in
                if let i = rects.firstIndex(where: { $0.contains(value.location) }) { onOpen(items[i]) }
            })
            .simultaneousGesture(SpatialTapGesture().onEnded { value in
                selection = rects.firstIndex { $0.contains(value.location) }.map { items[$0].id }
            })
            .help(hovered.flatMap { id in items.first { $0.id == id } }.map { "\($0.name) — \(Fmt.fileBytes($0.size))" } ?? "")
        }
    }
}
