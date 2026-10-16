import Foundation
import IOKit

struct RegistryNode: Identifiable, Sendable {
    let id: UInt64
    let name: String
    let className: String
    var children: [RegistryNode]?

    var count: Int { 1 + (children?.reduce(0) { $0 + $1.count } ?? 0) }

    func filtered(_ query: String) -> [RegistryNode] {
        var matches: [RegistryNode] = []
        if name.localizedCaseInsensitiveContains(query) || className.localizedCaseInsensitiveContains(query) {
            matches.append(RegistryNode(id: id, name: name, className: className, children: nil))
        }
        for child in children ?? [] { matches += child.filtered(query) }
        return matches
    }
}

struct PropertyNode: Identifiable, Sendable {
    let id: String
    let key: String
    let value: String
    var children: [PropertyNode]?
}

struct USBDevice: Identifiable, Sendable {
    let id: UInt64
    let name: String
    let vendor: String
    let vendorID: Int
    let productID: Int
    let speed: String
    let locationID: Int
    let serial: String?
}

enum IORegistry {
    static func serviceTree() -> RegistryNode {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        return node(for: root, depth: 0)
    }

    private static func node(for entry: io_registry_entry_t, depth: Int) -> RegistryNode {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(entry, &id)
        var nameBuf = [CChar](repeating: 0, count: 128)
        IORegistryEntryGetName(entry, &nameBuf)
        let className = (IOObjectCopyClass(entry)?.takeRetainedValue() as String?) ?? "?"

        var children: [RegistryNode] = []
        var iterator: io_iterator_t = 0
        if depth < 64, IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS {
            while case let child = IOIteratorNext(iterator), child != 0 {
                children.append(node(for: child, depth: depth + 1))
                IOObjectRelease(child)
            }
            IOObjectRelease(iterator)
        }
        return RegistryNode(id: id, name: String(cBuffer: nameBuf), className: className, children: children.isEmpty ? nil : children)
    }

    static func properties(entryID: UInt64) -> [PropertyNode] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(entryID))
        guard service != 0 else { return [] }
        defer { IOObjectRelease(service) }
        return IOKitHelpers.properties(service)
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { property(key: $0.key, value: $0.value, path: $0.key) }
    }

    static func property(key: String, value: Any, path: String) -> PropertyNode {
        switch value {
        case let dict as [String: Any]:
            let children = dict.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                .map { property(key: $0.key, value: $0.value, path: path + "/" + $0.key) }
            return PropertyNode(id: path, key: key, value: "\(dict.count) items", children: children)
        case let array as [Any]:
            let children = array.enumerated().map { property(key: "[\($0.offset)]", value: $0.element, path: path + "/\($0.offset)") }
            return PropertyNode(id: path, key: key, value: "\(array.count) items", children: children)
        default:
            return PropertyNode(id: path, key: key, value: describe(value), children: nil)
        }
    }

    static func describe(_ value: Any) -> String {
        switch value {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "Yes" : "No" }
            if CFNumberIsFloatType(n) { return "\(n.doubleValue)" }
            let v = n.int64Value
            return v > 9 || v < 0 ? "\(v) (0x\(String(UInt64(bitPattern: v), radix: 16)))" : "\(v)"
        case let s as String:
            return s
        case let d as Data:
            let trimmed = d.last == 0 ? d.dropLast() : d[...]
            if !trimmed.isEmpty, trimmed.allSatisfy({ (0x20...0x7e).contains($0) || $0 == 0 }) {
                return "\"" + String(decoding: trimmed.map { $0 == 0 ? UInt8(ascii: ",") : $0 }, as: UTF8.self) + "\""
            }
            let hex = d.prefix(64).map { String(format: "%02x", $0) }.joined()
            return "<\(hex)\(d.count > 64 ? "…" : "")> (\(d.count) bytes)"
        default:
            return String(describing: value)
        }
    }

    static func usbDevices() -> [USBDevice] {
        var devices: [USBDevice] = []
        IOKitHelpers.forEachService(matching: "IOUSBHostDevice") { service in
            var id: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &id)
            let p = IOKitHelpers.properties(service)
            var nameBuf = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(service, &nameBuf)
            let speeds = ["Low (1.5 Mb/s)", "Full (12 Mb/s)", "High (480 Mb/s)", "Super (5 Gb/s)", "Super+ (10 Gb/s)", "Super+ (20 Gb/s)"]
            let speed = (p["Device Speed"] as? Int).map { speeds.indices.contains($0) ? speeds[$0] : "\($0)" } ?? "–"
            devices.append(USBDevice(
                id: id,
                name: (p["USB Product Name"] as? String) ?? (p["kUSBProductString"] as? String) ?? String(cBuffer: nameBuf),
                vendor: (p["USB Vendor Name"] as? String) ?? (p["kUSBVendorString"] as? String) ?? "–",
                vendorID: (p["idVendor"] as? Int) ?? 0,
                productID: (p["idProduct"] as? Int) ?? 0,
                speed: speed,
                locationID: (p["locationID"] as? Int) ?? 0,
                serial: (p["USB Serial Number"] as? String) ?? (p["kUSBSerialNumberString"] as? String)
            ))
        }
        return devices.sorted { $0.locationID < $1.locationID }
    }
}
