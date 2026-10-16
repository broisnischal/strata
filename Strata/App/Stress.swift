import AppKit
import SwiftUI

/// `--stress [seconds]`: drives the process table the way frantic clicking
/// would (filters, tree on and off, every sort, a new selection) ten times a
/// second on live data, then prints the footprint and quits. A crash fails it.
@MainActor
enum Stress {
    static var seconds: Double? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--stress") else { return nil }
        return i + 1 < args.count ? Double(args[i + 1]) ?? 30 : 30
    }

    @Observable @MainActor
    final class Model {
        var rows: [ProcessSample] = []
        var tracked: Set<Int32> = []
        var selection: Int32?
        var sort = ProcessSort()
    }

    private struct Host: View {
        @Bindable var model: Model
        var body: some View {
            ProcessTable(rows: model.rows, tracked: model.tracked, selection: $model.selection, sort: $model.sort)
        }
    }

    static func run(monitor: SystemMonitor, for seconds: Double) async {
        let model = Model()
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 1100, height: 760), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Host(model: model))
        window.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(2))

        var order = StableOrder()
        var steps = 0
        let start = Date.now
        let end = start.addingTimeInterval(seconds)
        var reported = 0
        while Date.now < end {
            let elapsed = Int(Date.now.timeIntervalSince(start))
            if elapsed >= reported + 5 {
                reported = elapsed
                print("t=\(elapsed)s steps=\(steps) footprint \(footprintMB()) MB")
            }
            let all = monitor.processes
            guard !all.isEmpty else { try? await Task.sleep(for: .milliseconds(100)); continue }
            if ProcessInfo.processInfo.environment["STRESS_MODE"] == "human" {
                // Someone using it hard: a click every 2 s, a filter every 3 s,
                // a reorder every 4 s, the tree and the sort every 10 s.
                var list = all
                switch (steps / 6) % 4 {
                case 1: list = all.filter { $0.uid == getuid() }
                case 2: list = all.filter { $0.uid != getuid() }
                case 3: list = all.filter { $0.name.localizedCaseInsensitiveContains("e") }
                default: break
                }
                if steps % 20 == 0 {
                    model.sort = ProcessSort(column: ProcessColumn.allCases[(steps / 20) % ProcessColumn.allCases.count], ascending: false)
                }
                let ordered = order.order(list, by: model.sort.less, every: 4)
                model.rows = (steps / 20) % 2 == 1 ? ProcessTree.build(ordered) : ordered
                if steps % 4 == 0 { model.selection = list.randomElement()?.pid }
                steps += 1
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }
            var list = all
            switch steps % 5 {
            case 1: list = all.filter { $0.uid == getuid() }
            case 2: list = all.filter { $0.uid != getuid() }
            case 3: list = all.filter { $0.name.localizedCaseInsensitiveContains(["a", "e", "kit", "d"][steps % 4]) }
            default: break
            }
            if steps % 7 == 0, ProcessInfo.processInfo.environment["STRESS_MODE"] != "values" {
                let column = ProcessColumn.allCases[steps % ProcessColumn.allCases.count]
                model.sort = ProcessSort(column: column, ascending: steps % 2 == 0)
            }
            let mode = ProcessInfo.processInfo.environment["STRESS_MODE"] ?? "all"
            if mode == "values" { list = all }
            let sort = model.sort
            let ordered = order.order(list, by: sort.less, every: mode == "values" ? 1e9 : 0.3, force: mode != "values" && steps % 3 == 0)
            model.rows = mode != "flat" && mode != "values" && steps % 4 < 2 ? ProcessTree.build(ordered) : ordered
            if mode != "noselect" && mode != "values" { model.selection = list.randomElement()?.pid }
            model.tracked = Set(list.prefix(steps % 9).map(\.pid))
            steps += 1
            try? await Task.sleep(for: .milliseconds(100))
        }
        print("stress ok: \(steps) steps in \(Int(seconds)) s, footprint \(footprintMB()) MB")
        // Then idle on the same table: does the memory come back?
        for t in [10, 20] {
            try? await Task.sleep(for: .seconds(10))
            print("idle +\(t)s footprint \(footprintMB()) MB")
        }
        window.close()
        exit(0)
    }

    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }
}
