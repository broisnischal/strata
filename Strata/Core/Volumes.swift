import Foundation

struct VolumeInfo: Identifiable, Sendable {
    var id: URL { url }
    let url: URL
    let name: String
    let format: String
    let capacity: Int64
    let available: Int64
    let availableForImportant: Int64
    let isInternal: Bool
    let isRemovable: Bool
    let isEjectable: Bool
    let isEncrypted: Bool
    let isRoot: Bool

    var used: Int64 { max(capacity - available, 0) }
    var purgeable: Int64 { max(availableForImportant - available, 0) }
    var usedFraction: Double { capacity > 0 ? Double(used) / Double(capacity) : 0 }
}

enum VolumeCatalog {
    private static let keys: [URLResourceKey] = [
        .volumeNameKey, .volumeLocalizedFormatDescriptionKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey, .volumeIsInternalKey, .volumeIsRemovableKey,
        .volumeIsEjectableKey, .volumeIsEncryptedKey, .volumeIsRootFileSystemKey,
    ]

    static func volumes() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return VolumeInfo(
                url: url,
                name: v.volumeName ?? url.lastPathComponent,
                format: v.volumeLocalizedFormatDescription ?? "–",
                capacity: Int64(v.volumeTotalCapacity ?? 0),
                available: Int64(v.volumeAvailableCapacity ?? 0),
                availableForImportant: v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0),
                isInternal: v.volumeIsInternal ?? false,
                isRemovable: v.volumeIsRemovable ?? false,
                isEjectable: v.volumeIsEjectable ?? false,
                isEncrypted: v.volumeIsEncrypted ?? false,
                isRoot: v.volumeIsRootFileSystem ?? false
            )
        }.sorted { ($0.isRoot ? 0 : 1, $0.name) < ($1.isRoot ? 0 : 1, $1.name) }
    }
}
