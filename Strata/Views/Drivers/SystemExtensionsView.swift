import SwiftUI

struct SystemExtensionsView: View {
    @State private var extensions: [SystemExtensionInfo]?
    @State private var search = ""
    @State private var selection: SystemExtensionInfo.ID?

    var body: some View {
        Group {
            if let extensions {
                let rows = extensions.filter {
                    search.isEmpty || $0.identifier.localizedCaseInsensitiveContains(search) || $0.categoryNames.localizedCaseInsensitiveContains(search)
                }
                Table(rows, selection: $selection) {
                    TableColumn("Extension") { e in
                        HStack(spacing: 6) {
                            Image(nsImage: IconCache.icon(forBundle: e.containerPath)).resizable().frame(width: 18, height: 18)
                            Text(e.identifier).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .width(min: 240, ideal: 340)
                    TableColumn("Type") { Text($0.categoryNames.capitalized) }.width(min: 80, ideal: 110)
                    TableColumn("Version") { Text($0.version) }.width(min: 70, ideal: 120)
                    TableColumn("Team") { Text($0.teamID).monospaced() }.width(90)
                    TableColumn("State") { e in
                        HStack(spacing: 6) {
                            StatusDot(color: e.isEnabled ? .green : .secondary)
                            Text(e.stateName.capitalized)
                        }
                    }
                    .width(min: 110, ideal: 150)
                    TableColumn("App") { e in
                        Text(e.containerPath.map { ($0 as NSString).lastPathComponent } ?? "–").foregroundStyle(.secondary)
                    }
                }
                .contextMenu(forSelectionType: SystemExtensionInfo.ID.self) { ids in
                    if let id = ids.first, let e = extensions.first(where: { $0.id == id }) {
                        Button("Copy Identifier") { copyToPasteboard(e.identifier) }
                        if let app = e.containerPath { Button("Reveal App in Finder") { reveal(app) } }
                    }
                }
                .overlay {
                    if extensions.isEmpty {
                        ContentUnavailableView("No System Extensions", systemImage: "shippingbox", description: Text("DriverKit, network, endpoint security and camera extensions appear here."))
                    }
                }
                .safeAreaInset(edge: .bottom) { footer("\(extensions.count) extensions · \(extensions.filter(\.isEnabled).count) enabled") }
            } else {
                LoadingView(text: "Loading system extensions…")
            }
        }
        .navigationTitle("System Extensions")
        .searchable(text: $search, placement: .toolbar)
        .toolbar {
            Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        }
        .task { await load() }
    }

    private func load() async {
        extensions = await offMain { ExtensionCatalog.systemExtensions() }
    }
}
