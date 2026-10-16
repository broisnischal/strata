import Observation
import SwiftUI

enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case overview, processes, tracked, alerts, kexts, systemExtensions, devices, volumes, diskUsage, launchItems, backgroundItems

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .processes: "Processes"
        case .tracked: "Tracked"
        case .alerts: "Alerts"
        case .kexts: "Kernel Extensions"
        case .systemExtensions: "System Extensions"
        case .devices: "Devices"
        case .volumes: "Volumes"
        case .diskUsage: "Disk Usage"
        case .launchItems: "Launch Items"
        case .backgroundItems: "Background Items"
        }
    }

    var icon: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .processes: "list.bullet.rectangle"
        case .tracked: "pin"
        case .alerts: "bell"
        case .kexts: "puzzlepiece.extension"
        case .systemExtensions: "shippingbox"
        case .devices: "cable.connector"
        case .volumes: "internaldrive"
        case .diskUsage: "square.grid.3x3.topleft.filled"
        case .launchItems: "bolt.horizontal"
        case .backgroundItems: "clock.arrow.circlepath"
        }
    }
}

@MainActor @Observable
final class AppModel {
    var selection: SidebarItem? = UserDefaults.standard.string(forKey: "page").flatMap(SidebarItem.init) ?? .overview {
        didSet { UserDefaults.standard.set(selection?.rawValue, forKey: "page") }
    }
    let diskUsage = DiskUsageModel()
    /// A process for the Processes page to select when it shows.
    var revealPID: Int32?

    func reveal(pid: Int32) {
        revealPID = pid
        selection = .processes
    }

    func scan(_ path: String) {
        selection = .diskUsage
        diskUsage.start(path: path)
    }
}

/// Runs blocking Core work off the main actor.
func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await Task.detached(priority: .userInitiated, operation: work).value
}
