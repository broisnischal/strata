import AppKit
import SwiftUI

enum ProcessColumn: String, CaseIterable {
    case name, cpu, memory, power, threads, cpuTime, diskRead, diskWrite, pid, user

    var title: String {
        switch self {
        case .name: "Process"
        case .cpu: "% CPU"
        case .memory: "Memory"
        case .power: "Power"
        case .threads: "Threads"
        case .cpuTime: "CPU Time"
        case .diskRead: "Disk Read"
        case .diskWrite: "Disk Write"
        case .pid: "PID"
        case .user: "User"
        }
    }

    var width: CGFloat {
        switch self {
        case .name: 250
        case .cpu: 62
        case .memory: 82
        case .power: 72
        case .threads: 60
        case .cpuTime: 82
        case .diskRead, .diskWrite: 84
        case .pid: 60
        case .user: 90
        }
    }

    var numeric: Bool { self != .name && self != .user }
    var secondary: Bool { ![.name, .cpu, .memory].contains(self) }
    /// Measures sort biggest first; names and IDs alphabetically.
    var startsAscending: Bool { [.name, .user, .pid].contains(self) }

    func text(_ p: ProcessSample) -> String {
        switch self {
        case .name: p.name
        case .cpu: Fmt.cpu(p.cpu)
        case .memory: Fmt.bytes(p.memory)
        case .power: p.power.map(Fmt.watts) ?? "–"
        case .threads: p.threads.map(String.init) ?? "–"
        case .cpuTime: Fmt.cpuTime(p.cpuTime)
        case .diskRead: p.diskRead.map(Fmt.rate) ?? "–"
        case .diskWrite: p.diskWrite.map(Fmt.rate) ?? "–"
        case .pid: String(p.pid)
        case .user: p.user
        }
    }

    /// Strictly less in this column, ascending.
    func less(_ a: ProcessSample, _ b: ProcessSample) -> Bool {
        switch self {
        case .name: a.name.localizedStandardCompare(b.name) == .orderedAscending
        case .cpu: a.cpu < b.cpu
        case .memory: a.memory < b.memory
        case .power: (a.power ?? -1) < (b.power ?? -1)
        case .threads: (a.threads ?? -1) < (b.threads ?? -1)
        case .cpuTime: a.cpuTime < b.cpuTime
        case .diskRead: (a.diskRead ?? -1) < (b.diskRead ?? -1)
        case .diskWrite: (a.diskWrite ?? -1) < (b.diskWrite ?? -1)
        case .pid: a.pid < b.pid
        case .user: a.user < b.user
        }
    }
}

struct ProcessSort: Equatable {
    var column: ProcessColumn = .cpu
    var ascending = false

    func less(_ a: ProcessSample, _ b: ProcessSample) -> Bool {
        if column.less(a, b) { return ascending }
        if column.less(b, a) { return !ascending }
        return a.pid < b.pid
    }
}

struct ProcessMenuItem {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }
}

/// The process list, in AppKit: a flat table of row slots. A reorder, a new
/// filter or the tree folding just rewrites what the visible slots show, and
/// a change in length adds or drops rows at the end, so the table never
/// reloads. (A full reload churns row views and their backing stores; done
/// every few seconds it cost hundreds of megabytes.) The tree is the same
/// list, indented, with a disclosure arrow on parents.
struct ProcessTable: NSViewRepresentable {
    let rows: [ProcessSample]
    let tracked: Set<Int32>
    @Binding var selection: Int32?
    @Binding var sort: ProcessSort
    var onPointing: (Bool) -> Void = { _ in }
    var onOpen: (Int32) -> Void = { _ in }
    var menu: (ProcessSample) -> [ProcessMenuItem?] = { _ in [] }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let c = context.coordinator
        let table = VisibleOnlyTableView()
        table.style = .inset
        table.rowHeight = 24
        table.intercellSpacing = NSSize(width: 8, height: 0)
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = false
        table.allowsColumnReordering = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        for column in ProcessColumn.allCases {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            col.title = column.title
            col.width = column.width
            col.minWidth = column == .name ? 140 : 44
            col.headerCell.alignment = column.numeric ? .right : .left
            col.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: column.startsAscending)
            table.addTableColumn(col)
        }
        table.autosaveName = "StrataProcessColumns"
        table.autosaveTableColumns = true
        table.dataSource = c
        table.delegate = c
        table.target = c
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        let menu = NSMenu()
        menu.delegate = c
        table.menu = menu

        let scroll = PointerScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.onPointing = { [weak c] in c?.parent?.onPointing($0) }
        c.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        struct Row {
            let sample: ProcessSample
            let depth: Int
            let parent: Bool
            let open: Bool
        }

        var parent: ProcessTable?
        weak var table: NSTableView?
        private var rows: [Row] = []
        private var collapsed: Set<Int32> = []
        private var quiet = false
        private var menuActions: [() -> Void] = []
        /// The selection as the table last reported it, to tell a click from
        /// a selection made elsewhere (which also scrolls to the row).
        private var reported: Int32?

        func apply() {
            guard let parent, let table else { return }
            quiet = true
            defer { quiet = false }
            let sort = parent.sort
            if table.sortDescriptors.first?.key != sort.column.rawValue || table.sortDescriptors.first?.ascending != sort.ascending {
                table.sortDescriptors = [NSSortDescriptor(key: sort.column.rawValue, ascending: sort.ascending)]
            }
            relayout()
            let selected = parent.selection
            let external = selected != reported
            if let selected, let row = rows.firstIndex(where: { $0.sample.pid == selected }) {
                if table.selectedRow != row { table.selectRowIndexes([row], byExtendingSelection: false) }
                if external { table.scrollRowToVisible(row) }
            } else if table.selectedRow >= 0 {
                table.deselectAll(nil)
            }
            reported = selected
        }

        /// Flatten the tree, then show it: only the length is news to the
        /// table; the visible slots are rewritten in place.
        private func relayout() {
            guard let parent, let table else { return }
            var next: [Row] = []
            next.reserveCapacity(rows.count)
            func walk(_ s: ProcessSample, depth: Int) {
                let kids = s.children ?? []
                let open = !collapsed.contains(s.pid)
                next.append(Row(sample: s, depth: depth, parent: !kids.isEmpty, open: open))
                if open { for k in kids { walk(k, depth: depth + 1) } }
            }
            for s in parent.rows { walk(s, depth: 0) }
            let old = rows.count
            rows = next
            if next.count != old { table.noteNumberOfRowsChanged() }
            refreshVisible()
        }

        private func refreshVisible() {
            guard let table else { return }
            let visible = table.rows(in: table.visibleRect)
            guard visible.length > 0 else { return }
            for row in visible.location..<min(visible.location + visible.length, rows.count) {
                for (i, col) in table.tableColumns.enumerated() {
                    guard let column = ProcessColumn(rawValue: col.identifier.rawValue),
                          let cell = table.view(atColumn: i, row: row, makeIfNecessary: false) else { continue }
                    configure(cell, column, rows[row])
                }
            }
        }

        private func toggle(_ pid: Int32) {
            if collapsed.contains(pid) { collapsed.remove(pid) } else { collapsed.insert(pid) }
            quiet = true
            relayout()
            if let selected = parent?.selection, let row = rows.firstIndex(where: { $0.sample.pid == selected }) {
                table?.selectRowIndexes([row], byExtendingSelection: false)
            } else {
                table?.deselectAll(nil)
            }
            quiet = false
        }

        // MARK: Data source and delegate

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !quiet, let d = tableView.sortDescriptors.first, let key = d.key, let column = ProcessColumn(rawValue: key) else { return }
            parent?.sort = ProcessSort(column: column, ascending: d.ascending)
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let column = ProcessColumn(rawValue: tableColumn.identifier.rawValue), rows.indices.contains(row) else { return nil }
            let id = NSUserInterfaceItemIdentifier("cell." + column.rawValue)
            let cell = tableView.makeView(withIdentifier: id, owner: nil) ?? {
                let view: NSView = column == .name ? NameCell() : TextCell(numeric: column.numeric)
                view.identifier = id
                return view
            }()
            configure(cell, column, rows[row])
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !quiet, let table else { return }
            let pid = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].sample.pid : nil
            reported = pid
            parent?.selection = pid
        }

        private func configure(_ view: NSView, _ column: ProcessColumn, _ row: Row) {
            let p = row.sample
            if let cell = view as? NameCell {
                cell.show(row, tracked: parent?.tracked.contains(p.pid) ?? false) { [weak self] in self?.toggle(p.pid) }
            } else if let cell = view as? TextCell {
                let text = column.text(p)
                if cell.label.stringValue != text { cell.label.stringValue = text }
                let color: NSColor = column == .cpu && p.cpu < 0.05 ? .tertiaryLabelColor : column.secondary ? .secondaryLabelColor : .labelColor
                if cell.label.textColor != color { cell.label.textColor = color }
            }
        }

        // MARK: Actions

        @objc func doubleClicked(_ sender: Any?) {
            guard let table, rows.indices.contains(table.clickedRow) else { return }
            parent?.onOpen(rows[table.clickedRow].sample.pid)
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            menuActions = []
            guard let table, rows.indices.contains(table.clickedRow), let parent else { return }
            for item in parent.menu(rows[table.clickedRow].sample) {
                guard let item else {
                    menu.addItem(.separator())
                    continue
                }
                let entry = NSMenuItem(title: item.title, action: #selector(runMenuItem(_:)), keyEquivalent: "")
                entry.target = self
                entry.tag = menuActions.count
                menuActions.append(item.action)
                menu.addItem(entry)
            }
        }

        @objc func runMenuItem(_ sender: NSMenuItem) {
            guard menuActions.indices.contains(sender.tag) else { return }
            menuActions[sender.tag]()
        }
    }
}

/// A table that prepares only the rows on screen. By default AppKit renders
/// a band of rows beyond the visible ones for responsive scrolling.
private final class VisibleOnlyTableView: NSTableView {
    override func prepareContent(in rect: NSRect) {
        super.prepareContent(in: visibleRect)
    }
}

/// A scroll view that says when the pointer is over it.
final class PointerScrollView: NSScrollView {
    override class var isCompatibleWithResponsiveScrolling: Bool { false }

    var onPointing: ((Bool) -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) { onPointing?(true) }
    override func mouseExited(with event: NSEvent) { onPointing?(false) }
}

private final class TextCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")

    init(numeric: Bool) {
        super.init(frame: .zero)
        label.font = numeric ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
        label.alignment = numeric ? .right : .left
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

private final class NameCell: NSTableCellView {
    private let disclosure = NSButton()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let pin = NSImageView(image: NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Tracked")!)
    private let lock = NSImageView(image: NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Limited")!)
    private var indent: NSLayoutConstraint!
    private var iconPath: String??
    private var onToggle: (() -> Void)?
    private static let open = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Collapse")!
    private static let shut = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Expand")!

    init() {
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let small = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
        for badge in [pin, lock] {
            badge.symbolConfiguration = small
            badge.contentTintColor = .tertiaryLabelColor
            badge.setContentHuggingPriority(.required, for: .horizontal)
        }
        disclosure.isBordered = false
        disclosure.imagePosition = .imageOnly
        disclosure.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        disclosure.contentTintColor = .secondaryLabelColor
        disclosure.target = self
        disclosure.action = #selector(toggle)
        icon.imageScaling = .scaleProportionallyUpOrDown
        let stack = NSStackView(views: [disclosure, icon, label, pin, lock])
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        textField = label
        imageView = icon
        indent = stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2)
        NSLayoutConstraint.activate([
            disclosure.widthAnchor.constraint(equalToConstant: 10),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            indent,
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func toggle() { onToggle?() }

    func show(_ row: ProcessTable.Coordinator.Row, tracked: Bool, toggle: @escaping () -> Void) {
        let p = row.sample
        onToggle = toggle
        if label.stringValue != p.name { label.stringValue = p.name }
        let path = p.bundlePath
        if iconPath != .some(path) {
            icon.image = IconCache.icon(forBundle: path)
            iconPath = .some(path)
        }
        let inset = 2 + CGFloat(row.depth) * 14
        if indent.constant != inset { indent.constant = inset }
        disclosure.isHidden = !row.parent
        if row.parent { disclosure.image = row.open ? Self.open : Self.shut }
        if pin.isHidden == tracked { pin.isHidden = !tracked }
        if lock.isHidden == p.limited { lock.isHidden = !p.limited }
        let tip = p.limited ? "Owned by \(p.user): CPU and memory come from ps; other details need admin." : nil
        if toolTip != tip { toolTip = tip }
    }
}
