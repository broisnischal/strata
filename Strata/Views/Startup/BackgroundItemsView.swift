import SwiftUI

struct BackgroundItemsView: View {
    @State private var items: [BackgroundItem]?
    @State private var search = ""
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            ErrorBanner(message: $error)
            if let items {
                let groups = Dictionary(grouping: filtered(items), by: \.uid).sorted { $0.key > $1.key }
                List {
                    ForEach(groups, id: \.key) { uid, entries in
                        Section(header: Text(uidTitle(uid))) {
                            ForEach(entries) { BackgroundItemRow(item: $0) }
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    footer("\(items.count) items · \(items.filter(\.isEnabled).count) enabled · from sfltool dumpbtm")
                }
            } else {
                ContentUnavailableView {
                    Label("Login & Background Items", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("macOS keeps login items, agents and helpers registered by apps in a database only root can read.")
                } actions: {
                    Button(loading ? "Loading…" : "Load as Administrator") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(loading)
                    Button("Open Login Items Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                    }
                }
            }
        }
        .navigationTitle("Background Items")
        .searchable(text: $search, placement: .toolbar)
        .toolbar {
            if items != nil {
                Button { Task { await load() } } label: { Label("Reload", systemImage: "arrow.clockwise") }.disabled(loading)
            }
        }
    }

    private func filtered(_ list: [BackgroundItem]) -> [BackgroundItem] {
        guard !search.isEmpty else { return list }
        return list.filter { item in item.fields.values.contains { $0.localizedCaseInsensitiveContains(search) } }
    }

    private func uidTitle(_ uid: Int) -> String {
        switch uid {
        case Int(getuid()): "Your Items (UID \(uid))"
        case 0: "System (root)"
        case -2: "Shared (nobody)"
        default: "UID \(uid)"
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            items = try await BackgroundItemsCatalog.load()
        } catch ShellError.cancelled {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct BackgroundItemRow: View {
    let item: BackgroundItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: IconCache.icon(forBundle: item.location?.range(of: ".app").map { String(item.location![..<$0.upperBound]) }))
                .resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name).fontWeight(.medium)
                    Badge(text: item.type.capitalized)
                    Badge(text: item.isEnabled ? "Enabled" : "Disabled", tint: item.isEnabled ? .green : .secondary)
                }
                if let dev = item.developer ?? item.teamID {
                    Text(dev + (item.teamID.map { " · \($0)" } ?? "")).font(.caption).foregroundStyle(.secondary)
                }
                if let location = item.location {
                    Text(location).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                Text(item.disposition).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
        .revealInFinderMenu(item.location)
    }
}
