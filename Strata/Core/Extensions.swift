import Foundation
import IOKit
import IOKit.kext

struct KextInfo: Identifiable, Sendable {
    let id: String
    let version: String
    let path: String?
    let started: Bool
    let retainCount: Int
    let loadSize: Int
    let tag: Int
    let dependencies: [Int]
    var isApple: Bool { id.hasPrefix("com.apple.") }
}

struct SystemExtensionInfo: Identifiable, Sendable {
    let id: String
    let identifier: String
    let version: String
    let teamID: String
    let state: String
    let categories: [String]
    let containerPath: String?

    var isEnabled: Bool { state.contains("enabled") }
    var categoryNames: String {
        categories.map { $0.replacingOccurrences(of: "com.apple.system_extension.", with: "") }
            .map { $0 == "cmio" ? "camera" : $0 == "driver_extension" ? "driver" : $0.replacingOccurrences(of: "_", with: " ") }
            .joined(separator: ", ")
    }
    var stateName: String { state.replacingOccurrences(of: "_", with: " ") }
}

enum ExtensionCatalog {
    static func loadedKexts() -> [KextInfo] {
        guard let info = KextManagerCopyLoadedKextInfo(nil, nil)?.takeRetainedValue() as? [String: [String: Any]] else { return [] }
        return info.map { id, d in
            KextInfo(
                id: id,
                version: (d["CFBundleVersion"] as? String) ?? "–",
                path: d["OSBundlePath"] as? String,
                started: (d["OSBundleStarted"] as? Bool) ?? false,
                retainCount: (d["OSBundleRetainCount"] as? Int) ?? 0,
                loadSize: (d["OSBundleLoadSize"] as? Int) ?? 0,
                tag: (d["OSBundleLoadTag"] as? Int) ?? 0,
                dependencies: (d["OSBundleDependencies"] as? [Int]) ?? []
            )
        }.sorted { $0.tag < $1.tag }
    }

    static func systemExtensions() -> [SystemExtensionInfo] {
        guard let data = FileManager.default.contents(atPath: "/Library/SystemExtensions/db.plist"),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let exts = plist["extensions"] as? [[String: Any]] else { return [] }
        return exts.compactMap { e in
            guard let identifier = e["identifier"] as? String else { return nil }
            let bv = e["bundleVersion"] as? [String: Any]
            let short = bv?["CFBundleShortVersionString"] as? String
            let build = bv?["CFBundleVersion"] as? String
            return SystemExtensionInfo(
                id: (e["uniqueID"] as? String) ?? identifier,
                identifier: identifier,
                version: [short, build.map { "(\($0))" }].compactMap { $0 }.joined(separator: " "),
                teamID: (e["teamID"] as? String) ?? "–",
                state: (e["state"] as? String) ?? "unknown",
                categories: (e["categories"] as? [String]) ?? [],
                containerPath: (e["container"] as? [String: Any])?["bundlePath"] as? String
            )
        }
    }
}
