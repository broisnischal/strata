import Foundation

/// Headless smoke test: `Strata --self-test` runs every sampler/loader once and prints results.
enum SelfTest {
    static func run() async -> Int32 {
        func line(_ label: String, _ value: String) { print(label.padding(toLength: 22, withPad: " ", startingAt: 0) + value) }
        let clock = ContinuousClock()

        let system = SystemSampler()
        let processes = ProcessSampler()
        _ = await system.sample()
        _ = await processes.sample()
        try? await Task.sleep(for: .milliseconds(800))
        let start = clock.now
        async let snapTask = system.sample()
        async let procsTask = processes.sample()
        let (snap, procs) = await (snapTask, procsTask)
        line("sample time", "\(clock.now - start)")

        let limited = procs.filter(\.limited).count
        line("processes", "\(procs.count) total, \(procs.count - limited) full, \(limited) limited (ps)")
        if let top = procs.max(by: { $0.cpu < $1.cpu }) { line("top CPU", "\(top.name) [\(top.pid)] \(Fmt.cpu(top.cpu))%") }
        if let top = procs.max(by: { ($0.power ?? 0) < ($1.power ?? 0) }) { line("top power", "\(top.name) \(Fmt.watts(top.power ?? 0))") }
        line("process power", Fmt.watts(procs.compactMap(\.power).reduce(0, +)))
        let kinds = Dictionary(grouping: snap.cores, by: \.kind).mapValues(\.count)
        line("CPU", "\(Fmt.percent(snap.cpu, digits: 1)) (user \(Fmt.percent(snap.cpuUser, digits: 1)), sys \(Fmt.percent(snap.cpuSystem, digits: 1))) cores \(snap.cores.count) P=\(kinds[.performance] ?? 0) E=\(kinds[.efficiency] ?? 0)")
        let m = snap.memory
        line("memory", "used \(Fmt.bytes(m.used)) / \(Fmt.bytes(m.total)) (app \(Fmt.bytes(m.app)), wired \(Fmt.bytes(m.wired)), compressed \(Fmt.bytes(m.compressed)), cached \(Fmt.bytes(m.cached)))")
        line("pressure", "\(m.pressureName) \(Fmt.percent(m.pressure)), swap \(Fmt.bytes(m.swapUsed))")
        line("GPU", snap.gpu.map { Fmt.percent($0) } ?? "n/a")
        line("network", "in \(Fmt.rate(snap.netIn)), out \(Fmt.rate(snap.netOut)), totals \(Fmt.fileBytes(snap.netTotalIn))/\(Fmt.fileBytes(snap.netTotalOut))")
        line("disk", "read \(Fmt.rate(snap.diskRead)), write \(Fmt.rate(snap.diskWrite))")
        line("system power", snap.systemPower.map(Fmt.watts) ?? "n/a")
        line("battery", snap.battery.map { "\(Fmt.percent($0.percent)) charging=\($0.isCharging) ac=\($0.onAC) cycles=\($0.cycleCount ?? -1)" } ?? "none")
        line("load / uptime", "\(snap.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: " ")) / \(Fmt.duration(snap.uptime)) / thermal \(snap.thermalName)")

        if let pid = procs.first(where: { $0.pid == getpid() })?.pid {
            let d = ProcessInspector.detail(pid: pid)
            line("self detail", "\(d.arguments.count) args, \(d.environment.count) env, \(d.files.count) files, \(d.sockets.count) sockets")
        }
        let kexts = ExtensionCatalog.loadedKexts()
        line("kexts", "\(kexts.count) loaded, \(kexts.filter { !$0.isApple }.count) third-party")
        let sysexts = ExtensionCatalog.systemExtensions()
        line("system extensions", "\(sysexts.count) (\(sysexts.filter(\.isEnabled).count) enabled)")
        line("USB devices", "\(IORegistry.usbDevices().count)")
        let t0 = clock.now
        let tree = IORegistry.serviceTree()
        line("registry nodes", "\(tree.count) in \(clock.now - t0)")
        if let first = tree.children?.first { line("root props", "\(IORegistry.properties(entryID: first.id).count) on \(first.name)") }
        let volumes = VolumeCatalog.volumes()
        line("volumes", volumes.map { "\($0.name) \(Fmt.fileBytes($0.used))/\(Fmt.fileBytes($0.capacity))" }.joined(separator: "; "))
        let t1 = clock.now
        let launch = await LaunchCatalog.items(includeApple: true)
        line("launch items", "\(launch.count) (\(launch.filter { !$0.scope.isApple }.count) non-Apple, \(launch.filter { $0.pid != nil }.count) running) in \(clock.now - t1)")
        if let item = launch.first(where: { !$0.scope.isApple && $0.program != nil }), let program = item.program {
            line("signer sample", "\(item.label): \(CodeSigning.signer(of: program))")
        }

        let scanner = DiskScanner()
        let t2 = clock.now
        if let node = await scanner.scan(path: NSHomeDirectory() + "/Library/Preferences") {
            line("disk scan", "~/Library/Preferences \(Fmt.fileBytes(node.size)), \(node.fileCount) files, \(node.children.count) children in \(clock.now - t2)")
        } else {
            line("disk scan", "failed")
        }
        let sample = BackgroundItemsCatalog.parse(" #1:\n                 Name: Demo\n          Disposition: [enabled, allowed] (0x3)\n                 Type: app (0x2)\n")
        line("btm parser", "\(sample.count) item, name=\(sample.first?.name ?? "-"), enabled=\(sample.first?.isEnabled ?? false)")

        let failures = await MainActor.run { logicChecks() }
        line("logic checks", failures.isEmpty ? "all passed" : "\(failures.count) FAILED")
        for f in failures { print("  FAIL: \(f)") }
        return failures.isEmpty ? 0 : 1
    }

    /// The ordering and alert rules, on synthetic samples; nothing is saved or sent.
    @MainActor
    static func logicChecks() -> [String] {
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }

        struct Item: Identifiable { let id: Int32; var v: Double }
        let less: (Item, Item) -> Bool = { $0.v > $1.v }
        let t0 = Date()
        var order = StableOrder()
        var items = [Item(id: 1, v: 10), Item(id: 2, v: 5), Item(id: 3, v: 1)]
        check(order.order(items, by: less, every: 4, now: t0).map(\.id) == [1, 2, 3], "first ordering sorts")
        items[2].v = 50
        check(order.order(items, by: less, every: 4, now: t0 + 1).map(\.id) == [1, 2, 3], "positions hold between reorders")
        check(order.order(items + [Item(id: 4, v: 99)], by: less, every: 4, now: t0 + 2).map(\.id) == [1, 2, 3, 4], "a newcomer joins at the end")
        check(order.order(items, by: less, every: 4, frozen: true, now: t0 + 9).map(\.id) == [1, 2, 3], "frozen holds past the interval")
        check(order.order(items, by: less, every: 4, now: t0 + 10).map(\.id) == [3, 1, 2], "reorders once due")
        check(order.order(items, by: less, every: 4, force: true, now: t0 + 10.5).map(\.id) == [3, 1, 2], "forced reorder sorts")

        let alerts = AlertCenter(persist: false)
        let tracking = TrackingStore(persist: false)
        var snap = SystemSnapshot()
        snap.memory.total = 16 << 30
        snap.memory.app = 4 << 30
        var hog = ProcessSample(pid: 999_999, ppid: 1, uid: 501, user: "test", name: "spinner", path: nil)
        hog.cpu = 150
        let key = "proc-cpu-999999"
        for s in stride(from: 0.0, through: 130, by: 5) {
            snap.date = t0 + s
            alerts.evaluate(snap, [hog], tracking: tracking)
            if s < 120 { check(!alerts.events.contains { $0.key == key }, "no runaway alert before 2 minutes (at \(Int(s)) s)") }
        }
        check(alerts.events.filter { $0.key == key }.count == 1, "a runaway process alerts once after 2 minutes")
        check(alerts.active[key] != nil, "the runaway shows as active")
        snap.memory.pressureLevel = 4
        snap.date = t0 + 135
        alerts.evaluate(snap, [hog], tracking: tracking)
        check(alerts.events.first { $0.key == "pressure" }?.severity == .critical, "critical memory pressure alerts as critical")
        snap.date = t0 + 140
        alerts.evaluate(snap, [hog], tracking: tracking)
        check(alerts.events.filter { $0.key == "pressure" }.count == 1, "a lasting condition stays quiet for the cooldown")
        hog.cpu = 1
        snap.memory.pressureLevel = 1
        snap.date = t0 + 145
        alerts.evaluate(snap, [hog], tracking: tracking)
        check(alerts.active[key] == nil && alerts.active["pressure"] == nil, "conditions clear when they stop")
        alerts.evaluate(snap, [], tracking: tracking)
        check(alerts.active.keys.allSatisfy { !$0.hasPrefix("proc-") }, "an exited process leaves no active alert")

        tracking.targets = [TrackedTarget(match: .name("spinner"), title: "spinner", cpuLimit: 50, alertOnExit: true)]
        hog.cpu = 80
        for s in stride(from: 200.0, through: 235, by: 5) {
            tracking.update([hog], at: t0 + s)
            snap.date = t0 + s
            alerts.evaluate(snap, [hog], tracking: tracking)
        }
        check(alerts.events.contains { $0.key.hasPrefix("track-cpu-") }, "a tracked app over its CPU limit for 30 s alerts")
        check(tracking.status[tracking.targets[0].id]?.peakCPU == 80, "tracking keeps the peak")
        tracking.update([], at: t0 + 240)
        snap.date = t0 + 240
        alerts.evaluate(snap, [], tracking: tracking)
        check(alerts.events.contains { $0.key.hasPrefix("track-exit-") }, "a tracked app that stops alerts")
        return failures
    }
}
