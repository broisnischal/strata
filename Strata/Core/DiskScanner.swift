import Darwin
import Foundation

final class FileNode: Identifiable, Sendable {
    let name: String
    let path: String
    let size: Int64
    let isDirectory: Bool
    let fileCount: Int
    let children: [FileNode]
    let isAggregate: Bool
    let unreadable: Bool

    var id: String { path }

    init(name: String, path: String, size: Int64, isDirectory: Bool, fileCount: Int,
         children: [FileNode] = [], isAggregate: Bool = false, unreadable: Bool = false) {
        self.name = name
        self.path = path
        self.size = size
        self.isDirectory = isDirectory
        self.fileCount = fileCount
        self.children = children
        self.isAggregate = isAggregate
        self.unreadable = unreadable
    }
}

struct ScanProgress: Sendable {
    var files = 0
    var bytes: Int64 = 0
    var unreadable = 0
    var current = ""
}

/// Parallel, cancellable directory-size scanner. Doesn't cross devices or follow symlinks,
/// counts hard links once, and folds files under `smallFileLimit` into one node per folder.
final class DiskScanner: Sendable {
    static let smallFileLimit: Int64 = 256 * 1024
    private static let parallelDepth = 2

    let progress = Locked(ScanProgress())
    private let seenLinks = Locked(Set<HardLink>())

    private struct HardLink: Hashable, Sendable { let dev: dev_t; let ino: ino_t }

    private struct Listing {
        var files: [FileNode] = []
        var smallBytes: Int64 = 0
        var smallCount = 0
        var directories: [String] = []
        var ownSize: Int64 = 0
        var unreadable = false
    }

    static func effectiveRoot(_ path: String) -> String {
        path == "/" ? "/System/Volumes/Data" : path
    }

    func scan(path: String) async -> FileNode? {
        let root = Self.effectiveRoot(path)
        var st = stat()
        guard lstat(root, &st) == 0 else { return nil }
        let name = root == "/System/Volumes/Data" ? "Macintosh HD" : (root as NSString).lastPathComponent
        let node = await scanDirectory(root, name: name, device: st.st_dev, depth: 0)
        return Task.isCancelled ? nil : node
    }

    private func scanDirectory(_ path: String, name: String, device: dev_t, depth: Int) async -> FileNode {
        let listing = list(path, device: device)
        var subdirs: [FileNode]
        if depth < Self.parallelDepth {
            subdirs = await withTaskGroup(of: FileNode.self) { group in
                for dir in listing.directories {
                    group.addTask { await self.scanDirectory(path + "/" + dir, name: dir, device: device, depth: depth + 1) }
                }
                return await group.reduce(into: []) { $0.append($1) }
            }
        } else {
            subdirs = listing.directories.map { scanDirectorySync(path + "/" + $0, name: $0, device: device) }
        }
        return assemble(path: path, name: name, listing: listing, subdirs: subdirs)
    }

    private func scanDirectorySync(_ path: String, name: String, device: dev_t) -> FileNode {
        let listing = list(path, device: device)
        let subdirs = listing.directories.map { scanDirectorySync(path + "/" + $0, name: $0, device: device) }
        return assemble(path: path, name: name, listing: listing, subdirs: subdirs)
    }

    private func assemble(path: String, name: String, listing: Listing, subdirs: [FileNode]) -> FileNode {
        var children = listing.files + subdirs
        if listing.smallCount > 0 {
            children.append(FileNode(name: "Smaller files (\(listing.smallCount))", path: path + "/\u{0}small",
                                     size: listing.smallBytes, isDirectory: false, fileCount: listing.smallCount, isAggregate: true))
        }
        children.sort { $0.size > $1.size }
        let size = listing.ownSize + children.reduce(0) { $0 + $1.size }
        let count = children.reduce(0) { $0 + ($1.isDirectory ? $1.fileCount : ($1.isAggregate ? $1.fileCount : 1)) }
        return FileNode(name: name, path: path, size: size, isDirectory: true, fileCount: count,
                        children: children, unreadable: listing.unreadable)
    }

    private func list(_ path: String, device: dev_t) -> Listing {
        var listing = Listing()
        guard !Task.isCancelled, let dir = opendir(path) else {
            listing.unreadable = !Task.isCancelled
            progress.withLock { $0.unreadable += 1 }
            return listing
        }
        defer { closedir(dir) }
        let fd = dirfd(dir)
        var st = stat()
        if fstat(fd, &st) == 0 { listing.ownSize = Int64(st.st_blocks) * 512 }

        var fileCount = 0
        var bytes: Int64 = 0
        while let entry = readdir(dir) {
            let name = cString(entry.pointee.d_name)
            if name == "." || name == ".." { continue }
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let mode = st.st_mode & S_IFMT
            if mode == S_IFDIR {
                if st.st_dev == device { listing.directories.append(name) }
                continue
            }
            var size = Int64(st.st_blocks) * 512
            if mode == S_IFREG, st.st_nlink > 1 {
                let link = HardLink(dev: st.st_dev, ino: st.st_ino)
                if !seenLinks.withLock({ $0.insert(link).inserted }) { size = 0 }
            }
            fileCount += 1
            bytes += size
            if size >= Self.smallFileLimit {
                listing.files.append(FileNode(name: name, path: path + "/" + name, size: size, isDirectory: false, fileCount: 1))
            } else {
                listing.smallBytes += size
                listing.smallCount += 1
            }
        }
        progress.withLock {
            $0.files += fileCount
            $0.bytes += bytes
            $0.current = path
        }
        return listing
    }
}
