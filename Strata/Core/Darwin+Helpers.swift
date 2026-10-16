import Darwin
import Foundation
import IOKit

enum Sysctl {
    static func integer(_ name: String) -> Int? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return nil }
        switch size {
        case 4:
            var v: Int32 = 0
            return sysctlbyname(name, &v, &size, nil, 0) == 0 ? Int(v) : nil
        case 8:
            var v: Int64 = 0
            return sysctlbyname(name, &v, &size, nil, 0) == 0 ? Int(v) : nil
        default:
            return nil
        }
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cBuffer: buf)
    }

    static func value<T: BitwiseCopyable>(_ name: String, initial: T) -> T? {
        var v = initial
        var size = MemoryLayout<T>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? v : nil
    }
}

enum MachTime {
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return (UInt64(tb.numer), UInt64(tb.denom))
    }()

    static func nanoseconds(_ ticks: UInt64) -> UInt64 {
        ticks / timebase.denom * timebase.numer + ticks % timebase.denom * timebase.numer / timebase.denom
    }

    static var now: UInt64 { DispatchTime.now().uptimeNanoseconds }
}

/// Reads a fixed-size C char array (imported as a tuple) without running past its end.
func cString<T>(_ tuple: T) -> String {
    withUnsafeBytes(of: tuple) { raw in
        let bytes = raw.bindMemory(to: UInt8.self)
        let end = bytes.firstIndex(of: 0) ?? bytes.count
        return String(decoding: bytes[..<end], as: UTF8.self)
    }
}

func userName(for uid: uid_t) -> String {
    var pwd = passwd()
    var result: UnsafeMutablePointer<passwd>?
    var buf = [CChar](repeating: 0, count: 1024)
    guard getpwuid_r(uid, &pwd, &buf, buf.count, &result) == 0, result != nil, let name = pwd.pw_name else {
        return String(uid)
    }
    return String(cString: name)
}

enum IOKitHelpers {
    static func forEachService(matching className: String, _ body: (io_service_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            body(service)
            IOObjectRelease(service)
        }
    }

    static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func properties(_ entry: io_registry_entry_t) -> [String: Any] {
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return [:] }
        return dict
    }
}

extension String {
    init(cBuffer: [CChar]) {
        let end = cBuffer.firstIndex(of: 0) ?? cBuffer.count
        self = String(decoding: cBuffer[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
