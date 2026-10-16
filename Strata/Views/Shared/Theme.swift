import AppKit
import SwiftUI

/// Design tokens. Surfaces are quiet neutrals; colour is kept for data and
/// status. Series hues are the validated reference palette (blue, orange,
/// aqua, yellow, in that fixed order), each with its own light and dark step.
enum Theme {
    static let canvas = Color(light: 0xF5F5F3, dark: 0x0E0E0F)
    static let surface = Color(light: 0xFFFFFF, dark: 0x19191A)
    static let well = Color(light: 0x000000, lightAlpha: 0.04, dark: 0xFFFFFF, darkAlpha: 0.06)
    static let hairline = Color(light: 0x000000, lightAlpha: 0.08, dark: 0xFFFFFF, darkAlpha: 0.08)
    static let grid = Color(light: 0x000000, lightAlpha: 0.06, dark: 0xFFFFFF, darkAlpha: 0.07)

    static let series1 = Color(light: 0x2A78D6, dark: 0x3987E5)
    static let series2 = Color(light: 0xEB6834, dark: 0xD95926)
    static let series3 = Color(light: 0x1BAF7A, dark: 0x199E70)
    static let series4 = Color(light: 0xEDA100, dark: 0xC98500)
    static let neutral = Color(light: 0x000000, lightAlpha: 0.18, dark: 0xFFFFFF, darkAlpha: 0.22)

    static let radius: CGFloat = 14
    static let gap: CGFloat = 14

    static let metric = Font.system(size: 26, weight: .semibold).monospacedDigit()
    static let metricSmall = Font.system(size: 17, weight: .semibold).monospacedDigit()
    static let title = Font.system(size: 12, weight: .semibold)
    static let caption = Font.system(size: 11)
}

/// Status colours are reserved for state and always shown with an icon and a
/// label, never alone.
enum Severity: String, Codable, Sendable, CaseIterable, Comparable {
    case good, warning, serious, critical

    var color: Color {
        switch self {
        case .good: Color(light: 0x0CA30C, dark: 0x0CA30C)
        case .warning: Color(light: 0xFAB219, dark: 0xFAB219)
        case .serious: Color(light: 0xEC835A, dark: 0xEC835A)
        case .critical: Color(light: 0xD03B3B, dark: 0xD03B3B)
        }
    }

    var icon: String {
        switch self {
        case .good: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .serious: "exclamationmark.octagon.fill"
        case .critical: "xmark.octagon.fill"
        }
    }

    var label: String {
        switch self {
        case .good: "Normal"
        case .warning: "Warning"
        case .serious: "Serious"
        case .critical: "Critical"
        }
    }

    static func < (a: Severity, b: Severity) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }

    /// The kernel's memory pressure level (1 normal, 2 warning, 4 critical).
    init(pressureLevel: Int) {
        self = pressureLevel >= 4 ? .critical : pressureLevel >= 2 ? .warning : .good
    }
}

extension Color {
    init(light: UInt32, lightAlpha: CGFloat = 1, dark: UInt32, darkAlpha: CGFloat = 1) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(hex: dark, alpha: darkAlpha)
                : NSColor(hex: light, alpha: lightAlpha)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// Light, dark, or whatever the system wears.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: Self { self }
    var title: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
