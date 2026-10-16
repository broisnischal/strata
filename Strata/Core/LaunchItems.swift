import Darwin
import Foundation
import Security

enum LaunchScope: String, Sendable, CaseIterable {
    case userAgent = "User Agent"
    case globalAgent = "Global Agent"
    case daemon = "Daemon"
    case appleAgent = "Apple Agent"
    case appleDaemon = "Apple Daemon"

    var isApple: Bool { self == .appleAgent || self == .appleDaemon }
    var isSystemDomain: Bool { self == .daemon || self == .appleDaemon }

    var directory: String {
        switch self {
        case .userAgent: NSHomeDirectory() + "/Library/LaunchAgents"
        case .globalAgent: "/Library/LaunchAgents"
        case .daemon: "/Library/LaunchDaemons"
        case .appleAgent: "/System/Library/LaunchAgents"
        case .appleDaemon: "/System/Library/LaunchDaemons"
        }
    }
}

struct LaunchItem: Identifiable, Sendable {
    var id: String { plistPath }
    let label: String
    let plistPath: String
    let scope: LaunchScope
    let program: String?
    let arguments: [String]
    let runAtLoad: Bool
    let keepAlive: Bool
    let schedule: String?
    let disabledInPlist: Bool
    var loaded = false
    var pid: Int32?
    var lastExit: String?
    var overrideDisabled: Bool?
    var signer: String?

    var isDisabled: Bool { overrideDisabled ?? disabledInPlist }
    var domain: String { scope.isSystemDomain ? "system" : "gui/\(getuid())" }
    var serviceTarget: String { "\(domain)/\(label)" }

    var statusText: String {
        if let pid { return "Running (\(pid))" }
        if isDisabled { return "Disabled" }
        return loaded ? "Loaded" : "Not loaded"
    }

    var trigger: String {
        var parts: [String] = []
        if runAtLoad { parts.append("At load") }
        if keepAlive { parts.append("Keep alive") }
        if let schedule { parts.append(schedule) }
        return parts.isEmpty ? "On demand" : parts.joined(separator: ", ")
    }
}

enum LaunchCatalog {
    static func items(includeApple: Bool) async -> [LaunchItem] {
        let scopes = LaunchScope.allCases.filter { includeApple || !$0.isApple }
        var items = scopes.flatMap(parse(scope:))

        async let userList = try? Shell.run("/bin/launchctl", ["list"])
        async let systemPrint = try? Shell.run("/bin/launchctl", ["print", "system"])
        async let userDisabled = try? Shell.run("/bin/launchctl", ["print-disabled", "gui/\(getuid())"])
        async let systemDisabled = try? Shell.run("/bin/launchctl", ["print-disabled", "system"])

        let userState = parseList(await userList?.stdout ?? "")
        let systemState = parseSystemServices(await systemPrint?.stdout ?? "")
        let userOverrides = parseDisabled(await userDisabled?.stdout ?? "")
        let systemOverrides = parseDisabled(await systemDisabled?.stdout ?? "")

        for i in items.indices {
            let system = items[i].scope.isSystemDomain
            if let state = (system ? systemState : userState)[items[i].label] {
                items[i].loaded = true
                items[i].pid = state.pid
                items[i].lastExit = state.status
            }
            items[i].overrideDisabled = (system ? systemOverrides : userOverrides)[items[i].label]
        }
        return items.sorted { ($0.scope.rawValue, $0.label) < ($1.scope.rawValue, $1.label) }
    }

    private static func parse(scope: LaunchScope) -> [LaunchItem] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: scope.directory)) ?? []
        return files.filter { $0.hasSuffix(".plist") }.compactMap { file in
            let path = scope.directory + "/" + file
            guard let data = FileManager.default.contents(atPath: path),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
            let args = (plist["ProgramArguments"] as? [String]) ?? []
            let program = (plist["Program"] as? String) ?? args.first ?? (plist["BundleProgram"] as? String)
            var schedule: String?
            if let interval = plist["StartInterval"] as? Int { schedule = "Every \(Fmt.duration(TimeInterval(interval)))" }
            else if plist["StartCalendarInterval"] != nil { schedule = "Calendar" }
            else if plist["WatchPaths"] != nil || plist["QueueDirectories"] != nil { schedule = "Path watch" }
            else if plist["MachServices"] != nil || plist["Sockets"] != nil { schedule = "On demand (IPC)" }
            let keepAlive: Bool = switch plist["KeepAlive"] {
            case let b as Bool: b
            case is [String: Any]: true
            default: false
            }
            return LaunchItem(
                label: (plist["Label"] as? String) ?? (file as NSString).deletingPathExtension,
                plistPath: path, scope: scope, program: program, arguments: args,
                runAtLoad: (plist["RunAtLoad"] as? Bool) ?? false, keepAlive: keepAlive,
                schedule: schedule, disabledInPlist: (plist["Disabled"] as? Bool) ?? false
            )
        }
    }

    struct ServiceState { let pid: Int32?; let status: String? }

    /// `launchctl list`: "PID\tStatus\tLabel".
    static func parseList(_ text: String) -> [String: ServiceState] {
        var result: [String: ServiceState] = [:]
        for line in text.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count >= 3 else { continue }
            result[String(cols[2])] = ServiceState(pid: Int32(cols[0]), status: cols[1] == "-" ? nil : String(cols[1]))
        }
        return result
    }

    /// `launchctl print system` services block: "pid status label" (pid 0 = not running).
    static func parseSystemServices(_ text: String) -> [String: ServiceState] {
        var result: [String: ServiceState] = [:]
        var inServices = false
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "services = {" { inServices = true; continue }
            guard inServices else { continue }
            if trimmed == "}" { break }
            let cols = trimmed.split(whereSeparator: \.isWhitespace)
            guard cols.count >= 3, let pid = Int32(cols[0]) else { continue }
            result[String(cols[2])] = ServiceState(pid: pid > 0 ? pid : nil, status: cols[1] == "-" ? nil : String(cols[1]))
        }
        return result
    }

    /// `launchctl print-disabled`: "\"label\" => disabled|enabled|true|false".
    static func parseDisabled(_ text: String) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let label = parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            result[label] = value == "disabled" || value == "true"
        }
        return result
    }

    // MARK: Actions

    enum Action: String { case enable, disable, load, unload }

    static func perform(_ action: Action, on item: LaunchItem) async throws {
        let args: [String] = switch action {
        case .enable: ["enable", item.serviceTarget]
        case .disable: ["disable", item.serviceTarget]
        case .load: ["bootstrap", item.domain, item.plistPath]
        case .unload: ["bootout", item.serviceTarget]
        }
        if item.scope.isSystemDomain {
            _ = try await Shell.runAsAdmin((["/bin/launchctl"] + args).map(Shell.quote).joined(separator: " "))
        } else {
            let result = try await Shell.run("/bin/launchctl", args)
            if !result.succeeded {
                throw ShellError.failed((result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }
}

enum CodeSigning {
    static func signer(of path: String) -> String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else {
            return FileManager.default.fileExists(atPath: path) ? "Unknown" : "Missing"
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return "Unsigned" }
        if let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certs.first,
           let summary = SecCertificateCopySubjectSummary(leaf) as String? {
            return summary
        }
        if let flags = dict[kSecCodeInfoFlags as String] as? UInt32, flags & SecCodeSignatureFlags.adhoc.rawValue != 0 {
            return "Ad-hoc signed"
        }
        return dict[kSecCodeInfoIdentifier as String] == nil ? "Unsigned" : "Signed"
    }
}
