import SwiftUI

struct KextsView: View {
    @AppStorage("showAppleKexts") private var showApple = true
    @State private var kexts: [KextInfo]?
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\KextInfo.tag)]
    @State private var selection: KextInfo.ID?

    var body: some View {
        Group {
            if let kexts {
                let rows = filtered(kexts)
                Table(rows, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("#", value: \.tag) { Text(verbatim: "\($0.tag)").monospacedDigit() }.width(40)
                    TableColumn("Bundle ID", value: \.id) { k in
                        HStack(spacing: 6) {
                            Text(k.id).lineLimit(1).truncationMode(.middle)
                            if !k.isApple { Badge(text: "Third-party", tint: .orange) }
                        }
                    }
                    .width(min: 240, ideal: 340)
                    TableColumn("Version", value: \.version).width(min: 60, ideal: 80)
                    TableColumn("Size", value: \.loadSize) { Text($0.loadSize > 0 ? Fmt.bytes($0.loadSize) : "–").monospacedDigit() }.width(70)
                    TableColumn("Refs", value: \.retainCount) { Text(verbatim: "\($0.retainCount)").monospacedDigit() }.width(44)
                    TableColumn("Started", value: \.sortStarted) { k in
                        Image(systemName: k.started ? "checkmark.circle.fill" : "circle").foregroundStyle(k.started ? .green : .secondary)
                    }
                    .width(56)
                    TableColumn("Path") { Text($0.path ?? "–").foregroundStyle(.secondary).lineLimit(1).truncationMode(.head) }
                }
                .contextMenu(forSelectionType: KextInfo.ID.self) { ids in
                    if let id = ids.first, let kext = kexts.first(where: { $0.id == id }) {
                        Button("Copy Bundle ID") { copyToPasteboard(kext.id) }
                        if let path = kext.path { Button("Reveal in Finder") { reveal(path) } }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    footer("\(rows.count) shown · \(kexts.count) loaded · \(kexts.filter { !$0.isApple }.count) third-party")
                }
            } else {
                LoadingView(text: "Loading kernel extensions…")
            }
        }
        .navigationTitle("Kernel Extensions")
        .searchable(text: $search, placement: .toolbar)
        .toolbar {
            Toggle(isOn: $showApple) { Label("Apple", systemImage: "apple.logo") }.help("Show Apple kernel extensions")
            Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        }
        .task { await load() }
    }

    private func filtered(_ list: [KextInfo]) -> [KextInfo] {
        list.filter { (showApple || !$0.isApple) && (search.isEmpty || $0.id.localizedCaseInsensitiveContains(search)) }
            .sorted(using: sortOrder)
    }

    private func load() async {
        kexts = await offMain { ExtensionCatalog.loadedKexts() }
    }
}

extension KextInfo {
    var sortStarted: Int { started ? 1 : 0 }
}

func footer(_ text: String) -> some View {
    HStack {
        Text(text)
        Spacer()
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(.bar)
}
