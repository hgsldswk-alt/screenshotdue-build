import Foundation

enum TemplateKind: String, Codable, CaseIterable {
    case voucher, reply, travel
    var title: String { L.t("template." + rawValue) }
}

struct TemplateItem: Codable, Equatable, Identifiable {
    var kind: TemplateKind
    var days: Int
    var hour: Int
    var id: String { "\(kind.rawValue)-\(days)-\(hour)" }
}

enum TemplateCode {
    private static let prefix = "STD1:"
    static let maxBytes = 2048
    static let examples = [
        TemplateItem(kind: .voucher, days: 1, hour: 9),
        TemplateItem(kind: .reply, days: 0, hour: 18),
        TemplateItem(kind: .travel, days: 7, hour: 9)
    ]

    private struct StrictItem: Decodable {
        let item: TemplateItem

        init(from decoder: Decoder) throws {
            struct Key: CodingKey {
                let stringValue: String
                var intValue: Int? { nil }
                init?(stringValue: String) { self.stringValue = stringValue }
                init?(intValue: Int) { return nil }
            }
            let container = try decoder.container(keyedBy: Key.self)
            guard Set(container.allKeys.map(\.stringValue)) == ["kind", "days", "hour"] else {
                throw StorageError.invalidTemplate
            }
            item = try TemplateItem(from: decoder)
        }
    }

    static func encode(_ entries: [TemplateItem] = examples) throws -> String {
        try validate(entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(entries)
        return prefix + data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ raw: String) throws -> [TemplateItem] {
        guard raw.utf8.count <= maxBytes else { throw StorageError.invalidTemplate }
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.hasPrefix(prefix) else { throw StorageError.invalidTemplate }
        let token = String(code.dropFirst(prefix.count))
        guard !token.isEmpty, token.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }) else { throw StorageError.invalidTemplate }
        let base64 = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padding = String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64 + padding),
              let decoded = try? JSONDecoder().decode([StrictItem].self, from: data) else {
            throw StorageError.invalidTemplate
        }
        let items = decoded.map(\.item)
        try validate(items)
        return items
    }

    private static func validate(_ items: [TemplateItem]) throws {
        guard (1...12).contains(items.count), Set(items.map(\.id)).count == items.count,
              items.allSatisfy({ (0...30).contains($0.days) && [9, 12, 18].contains($0.hour) }) else {
            throw StorageError.invalidTemplate
        }
    }
}
