import AppKit
import Observation

struct HistorySample: Identifiable, Sendable {
    let id: Int
    let date: Date
    var cpuUser: Double
    var cpuSystem: Double
    var gpu: Double
    var memoryUsed: Double
    var pressure: Double
    var netIn: Double
    var netOut: Double
    var diskRead: Double
    var diskWrite: Double
    var power: Double
    var processPower: Double

    var cpu: Double { cpuUser + cpuSystem }
}

/// How far back the charts look.
enum HistoryWindow: Int, CaseIterable, Identifiable {
    case minute = 60, fiveMinutes = 300, fifteenMinutes = 900
    var id: Self { self }
    var title: String {
        switch self {
        case .minute: "1m"
        case .fiveMinutes: "5m"
        case .fifteenMinutes: "15m"
        }
    }
}

/// One process's recent values, for the inspector's charts.
struct ProcessPoint: Identifiable, Sendable {
    let id: Int
    let date: Date
    let cpu: Double
    let memory: Double
}

@MainActor @Observable
final class SystemMonitor {
    static let historyLength = 900
    static let intervals: [Double] = [0.5, 1, 2, 5]
    static let reorderIntervals: [Double] = [2, 4, 8, 15]
    /// Charts draw at most this many points; longer windows are averaged down.
    static let chartPoints = 150

    private(set) var snapshot = SystemSnapshot()
    private(set) var processes: [ProcessSample] = []
    private(set) var history: [HistorySample] = []
    private(set) var appPIDs: Set<Int32> = []
    private(set) var threadCount = 0
    private(set) var limitedCount = 0
    private(set) var processPower: Double = 0
    /// The busiest processes, in an order that holds for a few seconds.
    private(set) var topProcesses: [ProcessSample] = []
    private(set) var sequence = 0

    /// The process the inspector shows, and its recent values.
    var focusPID: Int32? {
        didSet { if focusPID != oldValue { focusHistory = [] } }
    }
    private(set) var focusHistory: [ProcessPoint] = []

    let tracking = TrackingStore()
    let alerts = AlertCenter()

    var interval: Double = UserDefaults.standard.object(forKey: "refreshInterval") as? Double ?? 1 {
        didSet { UserDefaults.standard.set(interval, forKey: "refreshInterval") }
    }
    var reorderInterval: Double = UserDefaults.standard.object(forKey: "reorderInterval") as? Double ?? 4 {
        didSet { UserDefaults.standard.set(reorderInterval, forKey: "reorderInterval") }
    }
    var window: HistoryWindow = HistoryWindow(rawValue: UserDefaults.standard.integer(forKey: "historyWindow")) ?? .minute {
        didSet { UserDefaults.standard.set(window.rawValue, forKey: "historyWindow") }
    }

    private let systemSampler = SystemSampler()
    private let processSampler = ProcessSampler()
    private var task: Task<Void, Never>?
    private var topOrder = StableOrder()

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: .seconds(self.interval))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func refresh() async {
        async let snap = systemSampler.sample()
        async let procs = processSampler.sample()
        apply(await snap, await procs)
    }

    /// The history inside the chosen window, averaged down to at most
    /// `chartPoints` points.
    var visibleHistory: [HistorySample] {
        let cutoff = (history.last?.date ?? .now).addingTimeInterval(-Double(window.rawValue))
        let start = history.firstIndex { $0.date >= cutoff } ?? history.endIndex
        let slice = history[start...]
        let size = max(1, Int((Double(slice.count) / Double(Self.chartPoints)).rounded(.up)))
        guard size > 1 else { return Array(slice) }
        return stride(from: slice.startIndex, to: slice.endIndex, by: size).map { i in
            HistorySample.average(slice[i..<min(i + size, slice.endIndex)])
        }
    }

    /// Recent values of one metric, newest last, for sparklines.
    func recent(_ value: KeyPath<HistorySample, Double>, count: Int = 60) -> [Double] {
        history.suffix(count).map { $0[keyPath: value] }
    }

    private func apply(_ snap: SystemSnapshot, _ procs: [ProcessSample]) {
        snapshot = snap
        processes = procs
        processPower = procs.reduce(0) { $0 + ($1.power ?? 0) }
        threadCount = procs.reduce(0) { $0 + ($1.threads ?? 0) }
        limitedCount = procs.reduce(0) { $0 + ($1.limited ? 1 : 0) }
        if sequence % 5 == 0 {
            let apps = Set(NSWorkspace.shared.runningApplications.lazy.filter { $0.activationPolicy == .regular }.map(\.processIdentifier))
            if apps != appPIDs { appPIDs = apps }
        }
        // Ranked over every process, so which six show changes only at a reorder.
        topProcesses = Array(topOrder.order(procs, by: { $0.cpu > $1.cpu }, every: reorderInterval).prefix(6))

        sequence += 1
        let total = Double(max(snap.memory.total, 1))
        history.append(HistorySample(
            id: sequence, date: snap.date, cpuUser: snap.cpuUser, cpuSystem: snap.cpuSystem, gpu: snap.gpu ?? 0,
            memoryUsed: Double(snap.memory.used) / total, pressure: snap.memory.pressure,
            netIn: snap.netIn, netOut: snap.netOut, diskRead: snap.diskRead, diskWrite: snap.diskWrite,
            power: snap.systemPower ?? 0, processPower: processPower
        ))
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }

        if let pid = focusPID, let p = procs.first(where: { $0.pid == pid }) {
            focusHistory.append(ProcessPoint(id: sequence, date: snap.date, cpu: p.cpu, memory: Double(p.memory)))
            if focusHistory.count > 180 { focusHistory.removeFirst(focusHistory.count - 180) }
        }

        tracking.update(procs, at: snap.date)
        alerts.evaluate(snap, procs, tracking: tracking)
    }
}

extension HistorySample {
    static func average(_ samples: ArraySlice<HistorySample>) -> HistorySample {
        let n = Double(samples.count)
        func mean(_ k: KeyPath<HistorySample, Double>) -> Double { samples.reduce(0) { $0 + $1[keyPath: k] } / n }
        let last = samples[samples.endIndex - 1]
        return HistorySample(
            id: last.id, date: last.date, cpuUser: mean(\.cpuUser), cpuSystem: mean(\.cpuSystem), gpu: mean(\.gpu),
            memoryUsed: mean(\.memoryUsed), pressure: mean(\.pressure), netIn: mean(\.netIn), netOut: mean(\.netOut),
            diskRead: mean(\.diskRead), diskWrite: mean(\.diskWrite), power: mean(\.power), processPower: mean(\.processPower)
        )
    }
}
