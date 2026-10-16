import Foundation
import Synchronization

struct ShellResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
    var succeeded: Bool { status == 0 }
}

enum ShellError: LocalizedError, Equatable {
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: "The administrator request was cancelled."
        case .failed(let message): message.isEmpty ? "The command failed." : message
        }
    }
}

final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>
    init(_ value: Value) { mutex = Mutex(value) }
    var value: Value { mutex.withLock { $0 } }
    func withLock<R: Sendable>(_ body: (inout Value) -> R) -> R { mutex.withLock { body(&$0) } }
}

enum Shell {
    static func run(_ path: String, _ args: [String] = []) async throws -> ShellResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try runSync(path, args) })
            }
        }
    }

    static func runSync(_ path: String, _ args: [String]) throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()

        let errData = Locked(Data())
        let group = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            let data = err.fileHandleForReading.readDataToEndOfFile()
            errData.withLock { $0 = data }
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return ShellResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData.value, as: UTF8.self)
        )
    }

    /// Runs a shell command as root through the standard macOS authorization prompt.
    static func runAsAdmin(_ command: String) async throws -> ShellResult {
        let script = "do shell script \"\(appleScriptEscape(command))\" with administrator privileges without altering line endings"
        let result = try await run("/usr/bin/osascript", ["-e", script])
        guard result.succeeded else {
            if result.stderr.contains("-128") || result.stderr.localizedCaseInsensitiveContains("cancel") {
                throw ShellError.cancelled
            }
            throw ShellError.failed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }

    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
