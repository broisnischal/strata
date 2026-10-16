import AppKit
import Observation
@preconcurrency import UserNotifications

struct AlertEvent: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var date: Date
    var severity: Severity
    var title: String
    var detail: String
    var pid: Int32?
    /// What raised it: one key per condition (and per process, for process rules).
    var key: String
}

struct Threshold: Codable, Equatable, Sendable {
    var enabled: Bool
    var value: Double
    /// How long the condition must hold before it alerts.
    var seconds: Double = 0
}

struct AlertRules: Codable, Equatable, Sendable {
    var notify = true
    var memoryPressure = true
    var memoryUsed = Threshold(enabled: true, value: 90)
    var swap = Threshold(enabled: true, value: 4)
    var systemCPU = Threshold(enabled: false, value: 90, seconds: 60)
    var processCPU = Threshold(enabled: true, value: 90, seconds: 120)
    var processMemory = Threshold(enabled: true, value: 4)
    var diskFree = Threshold(enabled: true, value: 10)
    var thermal = true
    var battery = Threshold(enabled: true, value: 15)
    var cooldownMinutes: Double = 15
}

/// Watches every sample against the rules. A condition alerts once when it
/// starts (after holding for its duration), then stays quiet for the cooldown
/// while it lasts; it shows as active until it clears.
@MainActor @Observable
final class AlertCenter {
    private static let rulesKey = "alertRules"
    private static let historyLimit = 300

    var rules: AlertRules {
        didSet { saveRules() }
    }
    private(set) var events: [AlertEvent] = []
    /// Conditions true right now, by key.
    private(set) var active: [String: AlertEvent] = [:]
    private(set) var unread = 0 {
        didSet { if persist { NSApp?.dockTile.badgeLabel = unread > 0 ? "\(unread)" : nil } }
    }

    private var since: [String: Date] = [:]
    private var lastFired: [String: Date] = [:]
    private var wasRunning: [UUID: Bool] = [:]
    private var diskCheckedAt = Date.distantPast
    private var diskFree: Int64?
    private var authorized: Bool?
    private let delegate = NotificationDelegate()
    /// Off for the self-test: nothing is read, saved or sent.
    private let persist: Bool

    init(persist: Bool = true) {
        self.persist = persist
        let data = persist ? UserDefaults.standard.data(forKey: Self.rulesKey) : nil
        rules = data.flatMap { try? JSONDecoder().decode(AlertRules.self, from: $0) } ?? AlertRules()
        events = persist ? Self.loadHistory() : []
        if persist { UNUserNotificationCenter.current().delegate = delegate }
    }

    var activeSorted: [AlertEvent] {
        active.values.sorted { ($0.severity, $0.date) > ($1.severity, $1.date) }
    }

    func markRead() { unread = 0 }

    func clearHistory() {
        events = []
        saveHistory()
    }

    // MARK: - Evaluation

    func evaluate(_ snap: SystemSnapshot, _ procs: [ProcessSample], tracking: TrackingStore) {
        let now = snap.date
        let r = rules
        let m = snap.memory
        var seen = Set<String>()
        func check(_ key: String, _ on: Bool, for seconds: Double = 0, _ make: () -> AlertEvent) {
            seen.insert(key)
            condition(key, on, for: seconds, now: now, make)
        }
        let topMemory = procs.sorted { $0.memory > $1.memory }.prefix(3)
            .map { "\($0.name) \(Fmt.bytes($0.memory))" }.joined(separator: ", ")

        let pressure = Severity(pressureLevel: m.pressureLevel)
        check("pressure", r.memoryPressure && pressure > .good) {
            event(pressure, "Memory pressure is \(pressure == .critical ? "critical" : "high")",
                  "\(Fmt.bytes(m.used)) of \(Fmt.bytes(m.total)) in use. Largest: \(topMemory).", key: "pressure", now)
        }
        let usedPercent = Double(m.used) / Double(max(m.total, 1)) * 100
        check("memory", r.memoryUsed.enabled && usedPercent >= r.memoryUsed.value) {
            event(.warning, "Memory is \(Int(usedPercent))% used",
                  "\(Fmt.bytes(m.used)) of \(Fmt.bytes(m.total)). Largest: \(topMemory).", key: "memory", now)
        }
        check("swap", r.swap.enabled && Double(m.swapUsed) >= r.swap.value * 1_073_741_824) {
            event(.warning, "Swap use is \(Fmt.bytes(m.swapUsed))",
                  "macOS is paging memory to disk, which slows everything down. Largest: \(topMemory).", key: "swap", now)
        }
        check("cpu", r.systemCPU.enabled && snap.cpu * 100 >= r.systemCPU.value, for: r.systemCPU.seconds) {
            let top = procs.max { $0.cpu < $1.cpu }
            return event(.warning, "CPU has been \(Fmt.percent(snap.cpu)) busy for \(Fmt.duration(r.systemCPU.seconds))",
                         top.map { "Busiest: \($0.name) at \(Fmt.cpu($0.cpu))%." } ?? "", key: "cpu", now)
        }
        if r.thermal {
            let level: Severity? = switch snap.thermal {
            case .serious: .serious
            case .critical: .critical
            default: nil
            }
            check("thermal", level != nil) {
                event(level ?? .serious, "The Mac is running hot", "Thermal state is \(snap.thermalName); macOS is slowing the CPU down.", key: "thermal", now)
            }
        }
        if let b = snap.battery {
            check("battery", r.battery.enabled && !b.onAC && b.percent * 100 <= r.battery.value) {
                event(.warning, "Battery is at \(Fmt.percent(b.percent))",
                      b.minutesRemaining.map { "About \(Fmt.duration(Double($0) * 60)) left." } ?? "Plug in soon.", key: "battery", now)
            }
        }
        if r.diskFree.enabled {
            if now.timeIntervalSince(diskCheckedAt) > 60 {
                diskCheckedAt = now
                diskFree = Self.startupDiskFree()
            }
            if let free = diskFree {
                check("disk", Double(free) < r.diskFree.value * 1_000_000_000) {
                    event(.serious, "Startup disk is almost full", "\(Fmt.fileBytes(free)) available.", key: "disk", now)
                }
            }
        }

        for p in procs {
            if r.processCPU.enabled {
                let key = "proc-cpu-\(p.pid)"
                check(key, p.cpu >= r.processCPU.value, for: r.processCPU.seconds) {
                    event(.warning, "\(p.name) has used \(Fmt.cpu(p.cpu))% CPU for \(Fmt.duration(r.processCPU.seconds))",
                          "PID \(p.pid), \(p.user). It may be stuck in a loop.", pid: p.pid, key: key, now)
                }
            }
            if r.processMemory.enabled {
                let key = "proc-mem-\(p.pid)"
                check(key, Double(p.memory) >= r.processMemory.value * 1_073_741_824) {
                    event(.warning, "\(p.name) is using \(Fmt.bytes(p.memory)) of memory",
                          "PID \(p.pid), \(p.user).", pid: p.pid, key: key, now)
                }
            }
        }

        for t in tracking.targets {
            guard let s = tracking.status[t.id] else { continue }
            if let limit = t.memoryLimit {
                let key = "track-mem-\(t.id)"
                check(key, s.memory > limit) {
                    event(.warning, "\(t.title) is using \(Fmt.bytes(s.memory))",
                          "Over its \(Fmt.bytes(limit)) limit, across \(s.pids.count) processes.", key: key, now)
                }
            }
            if let limit = t.cpuLimit {
                let key = "track-cpu-\(t.id)"
                check(key, s.cpu > limit, for: 30) {
                    event(.warning, "\(t.title) is using \(Fmt.cpu(s.cpu))% CPU",
                          "Over its \(Fmt.cpu(limit))% limit for 30 seconds.", key: key, now)
                }
            }
            if t.alertOnExit, wasRunning[t.id] == true, !s.running {
                post(event(.serious, "\(t.title) stopped running", "All of its processes have exited.", key: "track-exit-\(t.id)", now))
            }
            wasRunning[t.id] = s.running
        }

        // Conditions that weren't looked at (a process that exited, a rule
        // switched off) have cleared.
        for key in since.keys where !seen.contains(key) { since[key] = nil }
        for key in active.keys where !seen.contains(key) { active[key] = nil }
    }

    private func condition(_ key: String, _ on: Bool, for seconds: Double, now: Date, _ make: () -> AlertEvent) {
        guard on else {
            since[key] = nil
            active[key] = nil
            return
        }
        let start = since[key] ?? now
        since[key] = start
        guard now.timeIntervalSince(start) >= seconds else { return }
        let e = make()
        active[key] = e
        if let last = lastFired[key], now.timeIntervalSince(last) < rules.cooldownMinutes * 60 { return }
        lastFired[key] = now
        post(e)
    }

    private func event(_ severity: Severity, _ title: String, _ detail: String, pid: Int32? = nil, key: String, _ now: Date) -> AlertEvent {
        AlertEvent(date: now, severity: severity, title: title, detail: detail, pid: pid, key: key)
    }

    private func post(_ e: AlertEvent) {
        events.insert(e, at: 0)
        if events.count > Self.historyLimit { events.removeLast(events.count - Self.historyLimit) }
        unread += 1
        saveHistory()
        guard rules.notify, persist else { return }
        Task { await notify(e) }
    }

    private func notify(_ e: AlertEvent) async {
        let center = UNUserNotificationCenter.current()
        if authorized == nil {
            authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
        guard authorized == true else { return }
        let content = UNMutableNotificationContent()
        content.title = e.title
        content.body = e.detail
        content.threadIdentifier = e.key
        content.sound = e.severity >= .serious ? .default : nil
        try? await center.add(UNNotificationRequest(identifier: e.id.uuidString, content: content, trigger: nil))
    }

    // MARK: - Storage

    nonisolated private static func startupDiskFree() -> Int64? {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private func saveRules() {
        guard persist else { return }
        if let data = try? JSONEncoder().encode(rules) { UserDefaults.standard.set(data, forKey: Self.rulesKey) }
    }

    nonisolated private static var historyURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Strata", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("alerts.json")
    }

    nonisolated private static func loadHistory() -> [AlertEvent] {
        guard let data = try? Data(contentsOf: historyURL) else { return [] }
        return (try? JSONDecoder().decode([AlertEvent].self, from: data)) ?? []
    }

    private func saveHistory() {
        guard persist else { return }
        let events = events
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(events) { try? data.write(to: AlertCenter.historyURL, options: .atomic) }
        }
    }
}

/// Shows alerts as banners even while the app is in front, and brings the
/// Alerts page up when one is clicked.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let openAlerts = Notification.Name("Strata.openAlerts")

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run {
            NSApp.activate()
            NotificationCenter.default.post(name: Self.openAlerts, object: nil)
        }
    }
}
