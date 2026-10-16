import Darwin
import Foundation
import IOKit

struct CoreLoad: Sendable, Identifiable {
    let id: Int
    let kind: CoreKind
    let user: Double
    let system: Double
    var total: Double { user + system }
}

enum CoreKind: String, Sendable {
    case performance = "P", efficiency = "E", unknown = ""
}

struct MemoryStats: Sendable {
    var total: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var free: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var pressureLevel = 1
    var pressure: Double = 0
    var used: UInt64 { app + wired + compressed }

    var pressureName: String {
        switch pressureLevel {
        case 4: "Critical"
        case 2: "Warning"
        default: "Normal"
        }
    }
}

struct BatteryInfo: Sendable {
    var percent: Double
    var isCharging: Bool
    var onAC: Bool
    var minutesRemaining: Int?
    var cycleCount: Int?
    var healthPercent: Double?
}

struct SystemSnapshot: Sendable {
    var date = Date()
    var cores: [CoreLoad] = []
    var cpuUser: Double = 0
    var cpuSystem: Double = 0
    var memory = MemoryStats()
    var gpu: Double?
    var netIn: Double = 0
    var netOut: Double = 0
    var netTotalIn: UInt64 = 0
    var netTotalOut: UInt64 = 0
    var diskRead: Double = 0
    var diskWrite: Double = 0
    var loadAverage: [Double] = [0, 0, 0]
    var uptime: TimeInterval = 0
    var thermal: ProcessInfo.ThermalState = .nominal
    var systemPower: Double?
    var battery: BatteryInfo?
    var cpu: Double { cpuUser + cpuSystem }

    var thermalName: String {
        switch thermal {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }
}

actor SystemSampler {
    private static let host = mach_host_self()
    private let coreKinds = SystemSampler.readCoreKinds()
    private var prevCPU: [[UInt64]] = []
    private var prevNet: (UInt64, UInt64)?
    private var prevDisk: (UInt64, UInt64)?
    private var prevTime: UInt64 = 0

    /// Bytes per second between two readings of a counter. A counter that
    /// went backwards (an interface or a disk went away) counts as no traffic,
    /// not as the unsigned wrap-around.
    static func rate(_ now: UInt64, _ before: UInt64, _ seconds: Double) -> Double {
        now >= before ? Double(now - before) / seconds : 0
    }

    func sample() -> SystemSnapshot {
        let now = MachTime.now
        let dt = prevTime == 0 ? 0 : Double(now - prevTime) / 1e9
        prevTime = now

        var snap = SystemSnapshot()
        (snap.cores, snap.cpuUser, snap.cpuSystem) = cpuLoad()
        snap.memory = memory()
        snap.gpu = gpuUtilization()

        let net = networkBytes()
        snap.netTotalIn = net.0
        snap.netTotalOut = net.1
        if let prev = prevNet, dt > 0 {
            snap.netIn = Self.rate(net.0, prev.0, dt)
            snap.netOut = Self.rate(net.1, prev.1, dt)
        }
        prevNet = net

        let disk = diskBytes()
        if let prev = prevDisk, dt > 0 {
            snap.diskRead = Self.rate(disk.0, prev.0, dt)
            snap.diskWrite = Self.rate(disk.1, prev.1, dt)
        }
        prevDisk = disk

        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        snap.loadAverage = load
        if let boot = Sysctl.value("kern.boottime", initial: timeval()) {
            snap.uptime = Date().timeIntervalSince1970 - (Double(boot.tv_sec) + Double(boot.tv_usec) / 1e6)
        }
        snap.thermal = ProcessInfo.processInfo.thermalState
        (snap.systemPower, snap.battery) = power()
        return snap
    }

    // MARK: CPU

    private func cpuLoad() -> ([CoreLoad], Double, Double) {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(Self.host, PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return ([], 0, 0) }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        let stride = Int(CPU_STATE_MAX)
        let ticks: [[UInt64]] = (0..<Int(count)).map { core in
            (0..<stride).map { UInt64(UInt32(bitPattern: info[core * stride + $0])) }
        }
        defer { prevCPU = ticks }
        guard prevCPU.count == ticks.count else {
            return (ticks.indices.map { CoreLoad(id: $0, kind: coreKind($0), user: 0, system: 0) }, 0, 0)
        }

        var cores: [CoreLoad] = []
        var sumUser = 0.0, sumSystem = 0.0
        for (i, cur) in ticks.enumerated() {
            let d = zip(cur, prevCPU[i]).map { $0 &- $1 }
            let user = d[Int(CPU_STATE_USER)] + d[Int(CPU_STATE_NICE)]
            let system = d[Int(CPU_STATE_SYSTEM)]
            let total = Double(d.reduce(0, +))
            let u = total > 0 ? Double(user) / total : 0
            let s = total > 0 ? Double(system) / total : 0
            cores.append(CoreLoad(id: i, kind: coreKind(i), user: u, system: s))
            sumUser += u
            sumSystem += s
        }
        let n = Double(max(cores.count, 1))
        return (cores, sumUser / n, sumSystem / n)
    }

    private func coreKind(_ index: Int) -> CoreKind { coreKinds[index] ?? .unknown }

    private static func readCoreKinds() -> [Int: CoreKind] {
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpus != 0 else { return [:] }
        defer { IOObjectRelease(cpus) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iterator) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }
        var kinds: [Int: CoreKind] = [:]
        while case let cpu = IOIteratorNext(iterator), cpu != 0 {
            defer { IOObjectRelease(cpu) }
            guard let id = IOKitHelpers.property(cpu, "logical-cpu-id") as? Int,
                  let data = IOKitHelpers.property(cpu, "cluster-type") as? Data else { continue }
            kinds[id] = data.first == UInt8(ascii: "P") ? .performance : .efficiency
        }
        return kinds
    }

    // MARK: Memory

    private func memory() -> MemoryStats {
        var stats = MemoryStats()
        stats.total = UInt64(Sysctl.integer("hw.memsize") ?? 0)
        var vm = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(Self.host, HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let page = UInt64(getpagesize())
            let internalPages = UInt64(vm.internal_page_count), purgeable = UInt64(vm.purgeable_count)
            stats.app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
            stats.wired = UInt64(vm.wire_count) * page
            stats.compressed = UInt64(vm.compressor_page_count) * page
            stats.cached = (UInt64(vm.external_page_count) + purgeable) * page
            stats.free = (UInt64(vm.free_count) + UInt64(vm.speculative_count)) * page
        }
        if let swap = Sysctl.value("vm.swapusage", initial: xsw_usage()) {
            stats.swapUsed = swap.xsu_used
            stats.swapTotal = swap.xsu_total
        }
        stats.pressureLevel = Sysctl.integer("kern.memorystatus_vm_pressure_level") ?? 1
        if let level = Sysctl.integer("kern.memorystatus_level") {
            stats.pressure = Double(100 - level) / 100
        }
        return stats
    }

    // MARK: GPU

    private func gpuUtilization() -> Double? {
        var values: [Double] = []
        IOKitHelpers.forEachService(matching: "IOAccelerator") { service in
            if let stats = IOKitHelpers.property(service, "PerformanceStatistics") as? [String: Any],
               let util = stats["Device Utilization %"] as? Int {
                values.append(Double(util) / 100)
            }
        }
        return values.max()
    }

    // MARK: Network

    private static let virtualPrefixes = ["lo", "utun", "ipsec", "bridge", "gif", "stf", "llw"]

    private func networkBytes() -> (UInt64, UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return (0, 0) }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return (0, 0) }

        var rx: UInt64 = 0, tx: UInt64 = 0
        buf.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard hdr.ifm_msglen > 0 else { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2 {
                    let msg = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var nameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    let name = if_indextoname(UInt32(msg.ifm_index), &nameBuf).map { String(cString: $0) } ?? ""
                    if !Self.virtualPrefixes.contains(where: name.hasPrefix) {
                        rx += msg.ifm_data.ifi_ibytes
                        tx += msg.ifm_data.ifi_obytes
                    }
                }
                offset += Int(hdr.ifm_msglen)
            }
        }
        return (rx, tx)
    }

    // MARK: Disk

    private func diskBytes() -> (UInt64, UInt64) {
        var read: UInt64 = 0, write: UInt64 = 0
        IOKitHelpers.forEachService(matching: "IOBlockStorageDriver") { service in
            guard let stats = IOKitHelpers.property(service, "Statistics") as? [String: Any] else { return }
            read += (stats["Bytes (Read)"] as? UInt64) ?? 0
            write += (stats["Bytes (Write)"] as? UInt64) ?? 0
        }
        return (read, write)
    }

    // MARK: Power

    private func power() -> (Double?, BatteryInfo?) {
        var systemPower: Double?
        var battery: BatteryInfo?
        IOKitHelpers.forEachService(matching: "AppleSmartBattery") { service in
            let props = IOKitHelpers.properties(service)
            if let telemetry = props["PowerTelemetryData"] as? [String: Any], let load = telemetry["SystemLoad"] as? Int, load > 0 {
                systemPower = Double(load) / 1000
            }
            guard (props["BatteryInstalled"] as? Bool) ?? false else { return }
            let current = (props["CurrentCapacity"] as? Int) ?? 0
            let max = (props["MaxCapacity"] as? Int) ?? 100
            let rawMax = props["AppleRawMaxCapacity"] as? Int
            let design = props["DesignCapacity"] as? Int
            let timeRemaining = props["TimeRemaining"] as? Int
            let onAC = (props["ExternalConnected"] as? Bool) ?? false
            battery = BatteryInfo(
                percent: max > 0 ? Double(current) / Double(max) : 0,
                isCharging: (props["IsCharging"] as? Bool) ?? false,
                onAC: onAC,
                minutesRemaining: (timeRemaining ?? 0) > 0 && timeRemaining != 65535 ? timeRemaining : nil,
                cycleCount: props["CycleCount"] as? Int,
                healthPercent: rawMax.flatMap { raw in design.map { Double(raw) / Double($0) } }
            )
        }
        return (systemPower, battery)
    }
}
