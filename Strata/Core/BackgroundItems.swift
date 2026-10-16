import Foundation

struct BackgroundItem: Identifiable, Sendable {
    let id: String
    let uid: Int
    let fields: [String: String]

    var name: String { fields["Name"].flatMap { $0 == "(null)" ? nil : $0 } ?? fields["Identifier"] ?? "Unknown" }
    var developer: String? { fields["Developer Name"].flatMap { $0 == "(null)" ? nil : $0 } }
    var teamID: String? { fields["Team Identifier"].flatMap { $0 == "(null)" ? nil : $0 } }
    var type: String { fields["Type"].map(Self.stripCode) ?? "–" }
    var disposition: String { fields["Disposition"].map(Self.stripCode)?.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")) ?? "–" }
    var isEnabled: Bool { disposition.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == "enabled" } }
    var location: String? { fields["Executable Path"] ?? fields["URL"].flatMap { URL(string: $0)?.path } }

    private static func stripCode(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s*\(0x[0-9a-f]+\)$"#, with: "", options: .regularExpression)
    }
}

enum BackgroundItemsCatalog {
    static func load() async throws -> [BackgroundItem] {
        parse(try await Shell.runAsAdmin("/usr/bin/sfltool dumpbtm").stdout)
    }

    static func parse(_ text: String) -> [BackgroundItem] {
        var items: [BackgroundItem] = []
        var uid = -1
        var current: [String: String]?
        var index = 0

        func flush() {
            if let fields = current, !fields.isEmpty {
                items.append(BackgroundItem(id: "\(uid)-\(index)-\(fields["UUID"] ?? "")", uid: uid, fields: fields))
                index += 1
            }
            current = nil
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Records for UID") {
                flush()
                uid = Int(line.split(separator: " ").dropFirst(3).first?.trimmingCharacters(in: CharacterSet(charactersIn: ":")) ?? "") ?? -1
                continue
            }
            if line.range(of: #"^#\d+:$"#, options: .regularExpression) != nil {
                flush()
                current = [:]
                continue
            }
            guard current != nil, let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.hasPrefix("#"), current?[key] == nil else { continue }
            current?[key] = value
        }
        flush()
        return items
    }
}
