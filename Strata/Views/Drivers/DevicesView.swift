import SwiftUI

struct DevicesView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case usb = "USB", registry = "I/O Registry"
        var id: Self { self }
    }

    @State private var mode: Mode = .usb

    var body: some View {
        Group {
            switch mode {
            case .usb: USBDevicesView()
            case .registry: RegistryExplorerView()
            }
        }
        .navigationTitle("Devices")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
    }
}

private struct USBDevicesView: View {
    @State private var devices: [USBDevice]?

    var body: some View {
        Group {
            if let devices {
                Table(devices) {
                    TableColumn("Device") { Text($0.name) }.width(min: 160, ideal: 220)
                    TableColumn("Vendor") { Text($0.vendor) }.width(min: 100, ideal: 160)
                    TableColumn("ID") { Text("\(Fmt.hex($0.vendorID)):\(Fmt.hex($0.productID))").monospaced() }.width(120)
                    TableColumn("Speed") { Text($0.speed) }.width(min: 100, ideal: 120)
                    TableColumn("Location") { Text(Fmt.hex($0.locationID, width: 8)).monospaced() }.width(100)
                    TableColumn("Serial") { Text($0.serial ?? "–").textSelection(.enabled) }
                }
                .overlay {
                    if devices.isEmpty {
                        ContentUnavailableView("No USB Devices", systemImage: "cable.connector.slash", description: Text("Connected USB devices appear here."))
                    }
                }
            } else {
                LoadingView(text: "Scanning USB…")
            }
        }
        .toolbar {
            Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        }
        .task { await load() }
    }

    private func load() async {
        devices = await offMain { IORegistry.usbDevices() }
    }
}

private struct RegistryExplorerView: View {
    @State private var tree: RegistryNode?
    @State private var search = ""
    @State private var selection: RegistryNode.ID?
    @State private var properties: [PropertyNode] = []

    var body: some View {
        HSplitView {
            Group {
                if let tree {
                    if search.isEmpty {
                        List([tree], children: \.children, selection: $selection) { node in
                            RegistryRow(node: node)
                        }
                    } else {
                        let matches = tree.filtered(search)
                        List(matches, selection: $selection) { RegistryRow(node: $0) }
                            .overlay { if matches.isEmpty { ContentUnavailableView.search(text: search) } }
                    }
                } else {
                    LoadingView(text: "Reading I/O Registry…")
                }
            }
            .frame(minWidth: 280, idealWidth: 380)

            Group {
                if selection == nil {
                    ContentUnavailableView("Select an Entry", systemImage: "point.3.connected.trianglepath.dotted", description: Text("Properties of the selected registry entry appear here."))
                } else {
                    List(properties, children: \.children) { p in
                        HStack(alignment: .firstTextBaseline) {
                            Text(p.key).fontWeight(.medium).lineLimit(1)
                            Spacer(minLength: 12)
                            Text(p.value).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                                .lineLimit(3).multilineTextAlignment(.trailing).textSelection(.enabled)
                        }
                    }
                }
            }
            .frame(minWidth: 320, maxWidth: .infinity)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Name or class")
        .toolbar {
            Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        }
        .task { await load() }
        .task(id: selection) {
            guard let id = selection else { properties = []; return }
            properties = await offMain { IORegistry.properties(entryID: id) }
        }
    }

    private func load() async {
        tree = await offMain { IORegistry.serviceTree() }
    }
}

private struct RegistryRow: View {
    let node: RegistryNode

    var body: some View {
        HStack(spacing: 6) {
            Text(node.name).lineLimit(1)
            Text(node.className).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}
