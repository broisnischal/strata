import Darwin
import Foundation

struct ProcessSample: Identifiable, Sendable {
    let pid: Int32
    var ppid: Int32
    var uid: uid_t
    var user: String
    var name: String
    var path: String?
    var cpu: Double = 0
    var cpuTime: Double = 0
    var memory: UInt64 = 0
    var threads: Int?
    var power: Double?
    var diskRead: Double?
    var diskWrite: Double?
    var wakeups: Double?
    var limited = false
    var status: ProcessStatus = .unknown
    var children: [ProcessSample]?

    var id: Int32 { pid }

    /// The bundle that contains the executable, if any (innermost `.app`).
    var bundlePath: String? {
        guard let path, let range = path.range(of: ".app/", options: .backwards) else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    /// The app the executable belongs to (outermost `.app`), so a browser's
    /// helpers count as the browser.
    var appPath: String? {
        guard let path, let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }
}

enum ProcessStatus: String, Sendable {
    case idle = "Idle", running = "Running", sleeping = "Sleeping", stopped = "Stopped", zombie = "Zombie", unknown = "–"

    init(_ raw: UInt32) {
        switch Int32(raw) {
        case SIDL: self = .idle
        case SRUN: self = .running
        case SSLEEP: self = .sleeping
        case SSTOP: self = .stopped
        case SZOMB: self = .zombie
        default: self = .unknown
        }
    }
}

actor ProcessSampler {
    private struct Counters {
        var cpuNs: UInt64
        var energy: UInt64 = 0
        var diskRead: UInt64 = 0
        var diskWrite: UInt64 = 0
        var wakeups: UInt64 = 0
    }

    private struct Meta {
        let comm: String
        let name: String
        let path: String?
    }

    /// Rates as shown: averaged over about `smoothing` seconds, so one busy
    /// sample doesn't throw a process to the top of a list and back.
    private struct Smoothed {
        var cpu: Double
        var power: Double?
        var diskRead: Double?
        var diskWrite: Double?
    }

    static let smoothing: Double = 2.5

    private var previous: [Int32: Counters] = [:]
    private var smoothed: [Int32: Smoothed] = [:]
    private var meta: [Int32: Meta] = [:]
    private var users: [uid_t: String] = [:]
    private var prevTime: UInt64 = 0

    func sample() async -> [ProcessSample] {
        let now = MachTime.now
        let dtNs = prevTime == 0 ? 0 : Double(now - prevTime)
        prevTime = now

        var current: [Int32: Counters] = [:]
        var samples: [ProcessSample] = []
        var restricted: [Int: Int] = [:]  // pid → index in samples

        for pid in Self.allPids() {
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            let hasInfo = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size
            if !hasInfo && pid != 0 { continue }
            let comm = hasInfo ? cString(info.pbsi_comm) : "kernel_task"
            let m = metadata(pid: pid, comm: comm)
            let uid = hasInfo ? info.pbsi_uid : 0

            var sample = ProcessSample(
                pid: pid, ppid: hasInfo ? Int32(bitPattern: info.pbsi_ppid) : 0, uid: uid,
                user: user(uid), name: m.name, path: m.path,
                status: hasInfo ? ProcessStatus(info.pbsi_status) : .running
            )

            var ru = rusage_info_v6()
            let ok = withUnsafeMutablePointer(to: &ru) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
            } == 0

            if ok {
                let c = Counters(
                    cpuNs: MachTime.nanoseconds(ru.ri_user_time + ru.ri_system_time),
                    energy: ru.ri_energy_nj,
                    diskRead: ru.ri_diskio_bytesread,
                    diskWrite: ru.ri_diskio_byteswritten,
                    wakeups: ru.ri_interrupt_wkups + ru.ri_pkg_idle_wkups
                )
                current[pid] = c
                sample.cpuTime = Double(c.cpuNs) / 1e9
                sample.memory = ru.ri_phys_footprint
                var task = proc_taskinfo()
                if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size)) > 0 {
                    sample.threads = Int(task.pti_threadnum)
                }
                // A counter below its last reading means the PID was reused by
                // a new process: no delta this time, rather than a wrapped one.
                if let p = previous[pid], dtNs > 0, c.cpuNs >= p.cpuNs {
                    sample.cpu = Double(c.cpuNs - p.cpuNs) / dtNs * 100
                    sample.power = delta(c.energy, p.energy) / dtNs
                    sample.diskRead = delta(c.diskRead, p.diskRead) / dtNs * 1e9
                    sample.diskWrite = delta(c.diskWrite, p.diskWrite) / dtNs * 1e9
                    sample.wakeups = delta(c.wakeups, p.wakeups) / dtNs * 1e9
                }
            } else {
                sample.limited = true
                restricted[Int(pid)] = samples.count
            }
            samples.append(sample)
        }

        if !restricted.isEmpty, let ps = await Self.psStats() {
            for (pid, index) in restricted {
                guard let stat = ps[pid] else { continue }
                let cpuNs = UInt64(stat.cpuSeconds * 1e9)
                current[Int32(pid)] = Counters(cpuNs: cpuNs)
                samples[index].cpuTime = stat.cpuSeconds
                samples[index].memory = stat.rss
                if let p = previous[Int32(pid)], dtNs > 0, cpuNs >= p.cpuNs {
                    samples[index].cpu = Double(cpuNs - p.cpuNs) / dtNs * 100
                }
            }
        }

        previous = current
        smooth(&samples, seconds: dtNs / 1e9)
        let live = Set(samples.map(\.pid))
        meta = meta.filter { live.contains($0.key) }
        return samples
    }

    private func delta(_ now: UInt64, _ before: UInt64) -> Double {
        now >= before ? Double(now - before) : 0
    }

    private func smooth(_ samples: inout [ProcessSample], seconds: Double) {
        let alpha = seconds > 0 ? 1 - exp(-seconds / Self.smoothing) : 1
        func blend(_ old: Double?, _ new: Double?) -> Double? {
            guard let new else { return nil }
            guard let old else { return new }
            return old + alpha * (new - old)
        }
        var next: [Int32: Smoothed] = [:]
        next.reserveCapacity(samples.count)
        for i in samples.indices {
            let old = smoothed[samples[i].pid]
            let s = Smoothed(
                cpu: blend(old?.cpu, samples[i].cpu) ?? 0,
                power: blend(old?.power, samples[i].power),
                diskRead: blend(old?.diskRead, samples[i].diskRead),
                diskWrite: blend(old?.diskWrite, samples[i].diskWrite)
            )
            samples[i].cpu = s.cpu
            samples[i].power = s.power
            samples[i].diskRead = s.diskRead
            samples[i].diskWrite = s.diskWrite
            next[samples[i].pid] = s
        }
        smoothed = next
    }

    private func metadata(pid: Int32, comm: String) -> Meta {
        if let m = meta[pid], m.comm == comm { return m }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let path = proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cBuffer: buf) : nil
        let name = path.map { ($0 as NSString).lastPathComponent } ?? comm
        let m = Meta(comm: comm, name: name.isEmpty ? comm : name, path: path)
        meta[pid] = m
        return m
    }

    private func user(_ uid: uid_t) -> String {
        if let name = users[uid] { return name }
        let name = userName(for: uid)
        users[uid] = name
        return name
    }

    static func allPids() -> [Int32] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(estimate) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        return Array(pids.prefix(Int(max(n, 0))))
    }

    private struct PSStat { let rss: UInt64; let cpuSeconds: Double }

    /// `/bin/ps` is setuid root, so it can report CPU time and RSS for processes libproc can't read.
    private static func psStats() async -> [Int: PSStat]? {
        guard let result = try? await Shell.run("/bin/ps", ["-axo", "pid=,rss=,time="]), result.succeeded else { return nil }
        var stats: [Int: PSStat] = [:]
        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3, let pid = Int(parts[0]), let rss = UInt64(parts[1]) else { continue }
            stats[pid] = PSStat(rss: rss * 1024, cpuSeconds: parseCPUTime(parts[2]))
        }
        return stats
    }

    /// Parses `[[dd-]hh:]mm:ss.cc` into seconds.
    static func parseCPUTime<S: StringProtocol>(_ s: S) -> Double {
        var days = 0.0
        var rest = Substring(s)
        if let dash = rest.firstIndex(of: "-") {
            days = Double(rest[..<dash]) ?? 0
            rest = rest[rest.index(after: dash)...]
        }
        let seconds = rest.split(separator: ":").reduce(0.0) { $0 * 60 + (Double($1) ?? 0) }
        return days * 86400 + seconds
    }
}
