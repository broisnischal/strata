import AppKit
import Observation

@MainActor @Observable
final class DiskUsageModel {
    var path = NSHomeDirectory()
    private(set) var root: FileNode?
    private(set) var stack: [FileNode] = []
    private(set) var progress = ScanProgress()
    private(set) var isScanning = false
    private(set) var duration: Duration?
    private var task: Task<Void, Never>?

    var current: FileNode? { stack.last }

    func start(path: String? = nil) {
        if let path { self.path = path }
        cancel()
        let scanner = DiskScanner()
        let target = self.path
        isScanning = true
        root = nil
        stack = []
        progress = ScanProgress()
        duration = nil
        let started = ContinuousClock.now

        let poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                self?.progress = scanner.progress.value
            }
        }
        task = Task { [weak self] in
            let node = await Task.detached(priority: .userInitiated) { await scanner.scan(path: target) }.value
            poller.cancel()
            guard let self, !Task.isCancelled else { return }
            self.progress = scanner.progress.value
            self.root = node
            self.stack = node.map { [$0] } ?? []
            self.duration = ContinuousClock.now - started
            self.isScanning = false
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isScanning = false
    }

    func open(_ node: FileNode) {
        guard node.isDirectory, !node.children.isEmpty else { return }
        stack.append(node)
    }

    func pop(to node: FileNode) {
        guard let index = stack.firstIndex(where: { $0 === node }) else { return }
        stack.removeSubrange((index + 1)...)
    }

    func reveal(_ node: FileNode) {
        let path = node.isAggregate ? (node.path as NSString).deletingLastPathComponent : node.path
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Moves the item to the Trash and rebuilds the ancestors on the current stack with updated sizes.
    func trash(_ node: FileNode) throws {
        try FileManager.default.trashItem(at: URL(fileURLWithPath: node.path), resultingItemURL: nil)
        var replacement: FileNode?
        var removed = node
        for ancestor in stack.reversed() {
            let children = ancestor.children.compactMap { $0 === removed ? replacement : $0 }
            let delta = removed.size - (replacement?.size ?? 0)
            let countDelta = (removed.isDirectory ? removed.fileCount : 1) - (replacement?.fileCount ?? 0)
            let rebuilt = FileNode(name: ancestor.name, path: ancestor.path, size: ancestor.size - delta, isDirectory: true,
                                   fileCount: ancestor.fileCount - countDelta, children: children, unreadable: ancestor.unreadable)
            replacement = rebuilt
            removed = ancestor
        }
        guard let newRoot = replacement else { return }
        var newStack: [FileNode] = [newRoot]
        for old in stack.dropFirst() {
            guard let next = newStack.last?.children.first(where: { $0.path == old.path }) else { break }
            newStack.append(next)
        }
        root = newRoot
        stack = newStack
    }
}
