import CoreGraphics

enum Treemap {
    /// Squarified treemap layout. `sizes` must be sorted descending; returns one rect per size.
    static func layout(_ sizes: [Double], in rect: CGRect) -> [CGRect] {
        let total = sizes.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return sizes.map { _ in .zero } }
        let scale = Double(rect.width * rect.height) / total
        let areas = sizes.map { $0 * scale }
        var result = [CGRect](repeating: .zero, count: sizes.count)
        var remaining = rect
        var start = 0

        while start < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            var end = start + 1
            var best = worst(areas[start..<end], side: side)
            while end < areas.count {
                let next = worst(areas[start...end], side: side)
                if next > best { break }
                best = next
                end += 1
            }
            let rowArea = areas[start..<end].reduce(0, +)
            let horizontal = remaining.width >= remaining.height
            let thickness = CGFloat(rowArea / side)
            var offset: CGFloat = 0
            for i in start..<end {
                let length = CGFloat(areas[i] / rowArea * side)
                result[i] = horizontal
                    ? CGRect(x: remaining.minX, y: remaining.minY + offset, width: thickness, height: length)
                    : CGRect(x: remaining.minX + offset, y: remaining.minY, width: length, height: thickness)
                offset += length
            }
            if horizontal {
                remaining = CGRect(x: remaining.minX + thickness, y: remaining.minY, width: max(remaining.width - thickness, 0), height: remaining.height)
            } else {
                remaining = CGRect(x: remaining.minX, y: remaining.minY + thickness, width: remaining.width, height: max(remaining.height - thickness, 0))
            }
            start = end
        }
        return result
    }

    private static func worst(_ row: ArraySlice<Double>, side: Double) -> Double {
        let sum = row.reduce(0, +)
        guard let maxA = row.max(), let minA = row.min(), sum > 0, minA > 0 else { return .infinity }
        let s2 = side * side, sum2 = sum * sum
        return max(s2 * maxA / sum2, sum2 / (s2 * minA))
    }
}
