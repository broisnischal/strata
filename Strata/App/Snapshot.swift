import AppKit
import SwiftUI

/// `--snapshot <dir> [page…]`: renders pages into PNGs, in light and dark,
/// then quits. SwiftUI pages go through `ImageRenderer` and the Processes
/// table through the window itself, so this needs no Screen Recording
/// permission.
@MainActor
enum Snapshot {
    static var directory: URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1], isDirectory: true)
    }

    static func run(monitor: SystemMonitor, model: AppModel, into dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let named = CommandLine.arguments.drop { $0 != "--snapshot" }.dropFirst(2)
        let pages = named.compactMap(SidebarItem.init(rawValue:))
        let menu = named.isEmpty || named.contains("menubar")
        // Let the samplers fill some history first, with something tracked to show.
        try? await Task.sleep(for: .seconds(2))
        let seeded = monitor.tracking.targets.isEmpty
        if seeded {
            let apps = Dictionary(grouping: monitor.processes.filter { $0.appPath != nil }, by: \.appPath)
                .values.sorted { $0.reduce(0) { $0 + $1.memory } > $1.reduce(0) { $0 + $1.memory } }
            for group in apps.prefix(2) { if let p = group.first { monitor.tracking.track(p) } }
        }
        defer { if seeded { for t in monitor.tracking.targets { monitor.tracking.untrack(t.id) } } }
        try? await Task.sleep(for: .seconds(8))
        for (name, scheme) in [(NSAppearance.Name.aqua, ColorScheme.light), (.darkAqua, .dark)] {
            let appearance = NSAppearance(named: name)!
            NSApp.appearance = appearance
            let suffix = scheme == .light ? "light" : "dark"
            for page in pages.isEmpty && named.isEmpty ? SidebarItem.allCases : pages {
                model.selection = page
                try? await Task.sleep(for: .seconds(1.2))
                let url = dir.appendingPathComponent("\(page.rawValue)-\(suffix).png")
                if page == .processes {
                    await writeWindow(PageView(item: page), monitor: monitor, model: model, to: url)
                } else {
                    render(PageView(item: page).frame(width: 1180), monitor: monitor, model: model, scheme: scheme, appearance: appearance, to: url)
                }
            }
            if menu {
                render(MenuBarPanel().background(Theme.surface), monitor: monitor, model: model, scheme: scheme, appearance: appearance,
                       to: dir.appendingPathComponent("menubar-\(suffix).png"))
            }
        }
        NSApp.terminate(nil)
    }

    private static func render(_ view: some View, monitor: SystemMonitor, model: AppModel, scheme: ColorScheme, appearance: NSAppearance, to url: URL) {
        let content = view
            .environment(monitor)
            .environment(model)
            .environment(\.colorScheme, scheme)
            .environment(\.snapshotting, true)
            .background(Theme.canvas)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        appearance.performAsCurrentDrawingAppearance {
            guard let image = renderer.cgImage else { return }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        }
    }

    /// AppKit-backed views (the process table) don't go through
    /// `ImageRenderer`, so they're drawn in a window of their own, off screen.
    private static func writeWindow(_ view: some View, monitor: SystemMonitor, model: AppModel, to url: URL) async {
        let size = NSSize(width: 1180, height: 760)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: NavigationStack { view }.environment(monitor).environment(model))
        window.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(6))
        if let content = window.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        window.close()
    }
}
