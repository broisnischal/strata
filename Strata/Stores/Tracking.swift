import Foundation
import Observation

/// Something followed over time: an app (with all its helpers) or every
/// process of a name. It outlives the processes, so restarts keep their history.
struct TrackedTarget: Codable, Identifiable, Hashable, Sendable {
    enum Match: Codable, Hashable, Sendable {
        case app(String)
        case name(String)
    }

    var id = UUID()
    var match: Match
    var title: String
    var added = Date()
    /// Alert when it uses more than this much memory, in bytes.
    var memoryLimit: UInt64?
    /// Alert when it stays above this CPU (100 = one core) for 30 seconds.
    var cpuLimit: Double?
    /// Alert when its last process exits.
    var alertOnExit = false

    func matches(_ p: ProcessSample) -> Bool {
        switch match {
        case .app(let path): p.appPath == path
        case .name(let name): p.appPath == nil && p.name == name
        }
    }

    var appPath: String? {
        if case .app(let path) = match { path } else { nil }
    }

    var kindLabel: String {
        switch match {
        case .app: "App and its helpers"
        case .name(let name): "Processes named \(name)"
        }
    }
}

struct TrackedPoint: Identifiable, Sendable {
    let id: Int
    let date: Date
    let cpu: Double
    let memory: Double
    let power: Double
}

struct TrackedStatus: Sendable {
    var pids: [Int32] = []
    var cpu = 0.0
    var memory: UInt64 = 0
    var power = 0.0
    var threads = 0
    var peakCPU = 0.0
    var peakMemory: UInt64 = 0
    var cpuSum = 0.0
    var samples = 0
    /// When it last started running.
    var since: Date?
    var running: Bool { !pids.isEmpty }
    var averageCPU: Double { samples > 0 ? cpuSum / Double(samples) : 0 }
}

@MainActor @Observable
final class TrackingStore {
    static let historyLength = 900
    private static let key = "trackedTargets"

    var targets: [TrackedTarget] {
        didSet { save() }
    }
    private(set) var status: [UUID: TrackedStatus] = [:]
    private(set) var history: [UUID: [TrackedPoint]] = [:]
    private var tick = 0
    private let persist: Bool

    init(persist: Bool = true) {
        self.persist = persist
        let data = persist ? UserDefaults.standard.data(forKey: Self.key) : nil
        targets = data.flatMap { try? JSONDecoder().decode([TrackedTarget].self, from: $0) } ?? []
    }

    func update(_ processes: [ProcessSample], at date: Date) {
        tick += 1
        guard !targets.isEmpty else { return }
        var groups: [UUID: [ProcessSample]] = [:]
        for p in processes {
            for t in targets where t.matches(p) { groups[t.id, default: []].append(p) }
        }
        for t in targets {
            let mine = groups[t.id] ?? []
            var s = status[t.id] ?? TrackedStatus()
            let wasRunning = s.running
            s.pids = mine.map(\.pid)
            s.cpu = mine.reduce(0) { $0 + $1.cpu }
            s.memory = mine.reduce(0) { $0 + $1.memory }
            s.power = mine.reduce(0) { $0 + ($1.power ?? 0) }
            s.threads = mine.reduce(0) { $0 + ($1.threads ?? 0) }
            if s.running {
                if !wasRunning { s.since = date }
                s.peakCPU = max(s.peakCPU, s.cpu)
                s.peakMemory = max(s.peakMemory, s.memory)
                s.cpuSum += s.cpu
                s.samples += 1
            } else {
                s.since = nil
            }
            status[t.id] = s
            var points = history[t.id] ?? []
            points.append(TrackedPoint(id: tick, date: date, cpu: s.cpu, memory: Double(s.memory), power: s.power))
            if points.count > Self.historyLength { points.removeFirst(points.count - Self.historyLength) }
            history[t.id] = points
        }
    }

    func target(for p: ProcessSample) -> TrackedTarget? {
        targets.first { $0.matches(p) }
    }

    /// Track the app a process belongs to, or the process by name when it
    /// isn't part of an app.
    func track(_ p: ProcessSample) {
        guard target(for: p) == nil else { return }
        if let app = p.appPath {
            let title = (app as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            targets.append(TrackedTarget(match: .app(app), title: title))
        } else {
            targets.append(TrackedTarget(match: .name(p.name), title: p.name))
        }
    }

    func untrack(_ id: UUID) {
        targets.removeAll { $0.id == id }
        status[id] = nil
        history[id] = nil
    }

    func update(_ target: TrackedTarget) {
        guard let i = targets.firstIndex(where: { $0.id == target.id }) else { return }
        targets[i] = target
    }

    func resetPeaks(_ id: UUID) {
        guard var s = status[id] else { return }
        s.peakCPU = s.cpu
        s.peakMemory = s.memory
        s.cpuSum = 0
        s.samples = 0
        status[id] = s
    }

    private func save() {
        guard persist else { return }
        if let data = try? JSONEncoder().encode(targets) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
