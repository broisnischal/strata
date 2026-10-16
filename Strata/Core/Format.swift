import Foundation

enum Fmt {
    static func bytes<T: BinaryInteger>(_ value: T) -> String {
        value == 0 ? "0 B" : Int64(clamping: value).formatted(ByteCountFormatStyle(style: .memory, spellsOutZero: false))
    }

    static func fileBytes<T: BinaryInteger>(_ value: T) -> String {
        Int64(clamping: value).formatted(ByteCountFormatStyle(style: .file, spellsOutZero: false))
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond >= 1 else { return "0 B/s" }
        if bytesPerSecond < 1000 { return "\(Int(bytesPerSecond)) B/s" }
        return Int64(min(bytesPerSecond, 9e18)).formatted(ByteCountFormatStyle(style: .decimal, spellsOutZero: false)) + "/s"
    }

    /// An axis label for a percentage of one core: "25%", "12.5%".
    static func cpuAxis(_ percent: Double) -> String {
        percent.formatted(.number.precision(.fractionLength(0...1))) + "%"
    }

    static func percent(_ fraction: Double, digits: Int = 0) -> String {
        fraction.formatted(.percent.precision(.fractionLength(digits)))
    }

    static func cpu(_ percent: Double) -> String {
        percent.formatted(.number.precision(.fractionLength(1)))
    }

    static func watts(_ watts: Double) -> String {
        if watts < 0.01 { return "0 W" }
        if watts < 1 { return (watts * 1000).formatted(.number.precision(.fractionLength(0))) + " mW" }
        return watts.formatted(.number.precision(watts < 10 ? .fractionLength(2) : .fractionLength(0...1))) + " W"
    }

    static func cpuTime(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = seconds.truncatingRemainder(dividingBy: 60)
        let sec = s.formatted(.number.precision(.integerAndFractionLength(integer: 2, fraction: 2)))
        // Past an hour the hundredths are noise.
        return h > 0 ? "\(h):\(String(format: "%02d:%02d", m, total % 60))" : "\(m):\(sec)"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 86400 ? [.day, .hour, .minute] : [.hour, .minute, .second]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 3
        return f.string(from: seconds) ?? "–"
    }

    static func hex<T: BinaryInteger>(_ value: T, width: Int = 4) -> String {
        "0x" + String(String(value, radix: 16).leftPadded(to: width))
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: "0", count: width - count) + self
    }
}
