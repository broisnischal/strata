import Darwin
import Foundation

struct OpenFile: Identifiable, Sendable {
    let id: Int32
    let kind: String
    let path: String
}

struct SocketEntry: Identifiable, Sendable {
    let id: Int32
    let proto: String
    let local: String
    let remote: String
    let state: String
}

struct ProcessDetail: Sendable {
    var pid: Int32
    var path: String?
    var arguments: [String] = []
    var environment: [String] = []
    var workingDirectory: String?
    var startTime: Date?
    var files: [OpenFile] = []
    var sockets: [SocketEntry] = []
    var otherDescriptors = 0
    var accessible = true
}

enum ProcessInspector {
    static func detail(pid: Int32) -> ProcessDetail {
        var detail = ProcessDetail(pid: pid)
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 { detail.path = String(cBuffer: buf) }

        var bsd = proc_bsdinfo()
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 {
            detail.startTime = Date(timeIntervalSince1970: Double(bsd.pbi_start_tvsec) + Double(bsd.pbi_start_tvusec) / 1e6)
        } else {
            detail.accessible = false
        }

        var vnode = proc_vnodepathinfo()
        if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 {
            detail.workingDirectory = cString(vnode.pvi_cdir.vip_path)
        }

        (detail.arguments, detail.environment) = arguments(pid: pid)
        (detail.files, detail.sockets, detail.otherDescriptors) = descriptors(pid: pid)
        return detail
    }

    // MARK: Arguments

    static func arguments(pid: Int32) -> ([String], [String]) {
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mib, 2, &argmax, &size, nil, 0) == 0 else { return ([], []) }

        var buf = [UInt8](repeating: 0, count: Int(argmax))
        size = buf.count
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return ([], []) }

        // argc comes from the process's own memory: never trust it to be sane.
        let argc = max(0, Int(buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }))
        var i = MemoryLayout<Int32>.size
        while i < size, buf[i] != 0 { i += 1 }  // exec path
        while i < size, buf[i] == 0 { i += 1 }  // padding

        var strings: [String] = []
        var start = i
        while i < size {
            if buf[i] == 0 {
                if i > start { strings.append(String(decoding: buf[start..<i], as: UTF8.self)) } else if strings.count >= argc { break }
                start = i + 1
            }
            i += 1
        }
        let args = Array(strings.prefix(argc))
        let env = strings.dropFirst(argc).filter { $0.contains("=") }
        return (args, Array(env))
    }

    // MARK: File descriptors

    static func listFDs(pid: Int32) -> [proc_fdinfo] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 32)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        return got > 0 ? Array(fds.prefix(Int(got) / stride)) : []
    }

    static func vnodePath(pid: Int32, fd: Int32) -> String? {
        var info = vnode_fdinfowithpath()
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        guard proc_pidfdinfo(pid, fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { return nil }
        let path = cString(info.pvip.vip_path)
        return path.isEmpty ? nil : path
    }

    static func descriptors(pid: Int32) -> ([OpenFile], [SocketEntry], Int) {
        var files: [OpenFile] = []
        var sockets: [SocketEntry] = []
        var other = 0
        for fd in listFDs(pid: pid) {
            switch Int32(fd.proc_fdtype) {
            case PROX_FDTYPE_VNODE:
                if let path = vnodePath(pid: pid, fd: fd.proc_fd) {
                    files.append(OpenFile(id: fd.proc_fd, kind: "File", path: path))
                }
            case PROX_FDTYPE_SOCKET:
                if let socket = socket(pid: pid, fd: fd.proc_fd) { sockets.append(socket) }
            case PROX_FDTYPE_PIPE:
                files.append(OpenFile(id: fd.proc_fd, kind: "Pipe", path: "–"))
            default:
                other += 1
            }
        }
        return (files, sockets, other)
    }

    private static let tcpStates = ["CLOSED", "LISTEN", "SYN_SENT", "SYN_RECEIVED", "ESTABLISHED", "CLOSE_WAIT",
                                    "FIN_WAIT_1", "CLOSING", "LAST_ACK", "FIN_WAIT_2", "TIME_WAIT"]

    private static func socket(pid: Int32, fd: Int32) -> SocketEntry? {
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        guard proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &info, size) == size else { return nil }
        let psi = info.psi
        switch Int32(psi.soi_kind) {
        case Int32(SOCKINFO_TCP):
            let tcp = psi.soi_proto.pri_tcp
            let ini = tcp.tcpsi_ini
            let state = Int(tcp.tcpsi_state)
            return SocketEntry(
                id: fd, proto: ini.insi_vflag & UInt8(INI_IPV6) != 0 ? "TCP6" : "TCP",
                local: endpoint(ini, local: true), remote: endpoint(ini, local: false),
                state: tcpStates.indices.contains(state) ? tcpStates[state] : "\(state)"
            )
        case Int32(SOCKINFO_IN):
            let ini = psi.soi_proto.pri_in
            let udp = psi.soi_protocol == IPPROTO_UDP
            let v6 = ini.insi_vflag & UInt8(INI_IPV6) != 0
            return SocketEntry(
                id: fd, proto: (udp ? "UDP" : "IP") + (v6 ? "6" : ""),
                local: endpoint(ini, local: true), remote: endpoint(ini, local: false), state: ""
            )
        case Int32(SOCKINFO_UN):
            let path = cString(psi.soi_proto.pri_un.unsi_addr.ua_sun.sun_path)
            return SocketEntry(id: fd, proto: "Unix", local: path.isEmpty ? "–" : path, remote: "", state: "")
        default:
            return nil
        }
    }

    private static func endpoint(_ ini: in_sockinfo, local: Bool) -> String {
        let rawPort = local ? ini.insi_lport : ini.insi_fport
        let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: rawPort))
        let v6 = ini.insi_vflag & UInt8(INI_IPV6) != 0
        var host: String
        if v6 {
            var addr = local ? ini.insi_laddr.ina_6 : ini.insi_faddr.ina_6
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            inet_ntop(AF_INET6, &addr, &buf, socklen_t(buf.count))
            host = "[" + String(cBuffer: buf) + "]"
        } else {
            var addr = local ? ini.insi_laddr.ina_46.i46a_addr4 : ini.insi_faddr.ina_46.i46a_addr4
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &addr, &buf, socklen_t(buf.count))
            host = String(cBuffer: buf)
        }
        if port == 0 && (host == "0.0.0.0" || host == "[::]") { return local ? "*" : "" }
        if host == "0.0.0.0" || host == "[::]" { host = "*" }
        return "\(host):\(port == 0 ? "*" : String(port))"
    }

    // MARK: Who's using a path

    struct PathUser: Identifiable, Sendable {
        var id: String { "\(pid):\(path)" }
        let pid: Int32
        let name: String
        let path: String
    }

    /// Lists open vnodes under `prefix` across every process this user can inspect.
    static func users(ofPathPrefix prefix: String) -> (users: [PathUser], skipped: Int) {
        var found: [PathUser] = []
        var skipped = 0
        let normalized = prefix.hasSuffix("/") ? prefix : prefix + "/"
        for pid in ProcessSampler.allPids() where pid > 0 {
            let fds = listFDs(pid: pid)
            if fds.isEmpty { skipped += 1; continue }
            var name: String?
            for fd in fds where Int32(fd.proc_fdtype) == PROX_FDTYPE_VNODE {
                guard let path = vnodePath(pid: pid, fd: fd.proc_fd), path == prefix || path.hasPrefix(normalized) else { continue }
                if name == nil {
                    var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
                    name = proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? (String(cBuffer: buf) as NSString).lastPathComponent : "\(pid)"
                }
                found.append(PathUser(pid: pid, name: name ?? "\(pid)", path: path))
            }
        }
        return (found, skipped)
    }
}
