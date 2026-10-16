import Foundation

/// A ranking that holds still between reorders. Values refresh with every
/// sample; positions change only every `interval` seconds (or when forced),
/// and never while frozen, so rows don't trade places under the pointer.
/// A process that appears in between joins at the end until the next reorder.
struct StableOrder {
    private(set) var rank: [Int32: Int] = [:]
    private var sortedAt = Date.distantPast

    mutating func order<T: Identifiable>(
        _ items: [T], by less: (T, T) -> Bool, every interval: TimeInterval,
        frozen: Bool = false, force: Bool = false, now: Date = .now
    ) -> [T] where T.ID == Int32 {
        let due = force || rank.isEmpty || (!frozen && now.timeIntervalSince(sortedAt) >= interval)
        if due {
            let sorted = items.sorted(by: less)
            rank = Dictionary(sorted.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
            sortedAt = now
            return sorted
        }
        var placed: [(Int, T)] = []
        var arrivals: [T] = []
        placed.reserveCapacity(items.count)
        for item in items {
            if let r = rank[item.id] { placed.append((r, item)) } else { arrivals.append(item) }
        }
        placed.sort { $0.0 < $1.0 }
        arrivals.sort(by: less)
        var next = (rank.values.max() ?? -1) + 1
        for item in arrivals {
            rank[item.id] = next
            next += 1
        }
        return placed.map(\.1) + arrivals
    }

    /// Where an item stands, for ordering siblings in a tree the same way.
    func position(of id: Int32) -> Int { rank[id] ?? .max }
}
