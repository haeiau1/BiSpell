import Foundation

public struct Note: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var title: String
    public var body: String
    public var createdAt: Date
    public var updatedAt: Date
    /// When true, note lives under Templates (not regular notes list).
    public var isTemplate: Bool
    /// UTF-16 ranges that are locked (read/copy only).
    public var lockedSpans: [LockedSpan]

    public init(
        id: UUID = UUID(),
        title: String = "Untitled",
        body: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isTemplate: Bool = false,
        lockedSpans: [LockedSpan] = []
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isTemplate = isTemplate
        self.lockedSpans = LockedSpanMath.normalize(lockedSpans)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled"
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        isTemplate = try c.decodeIfPresent(Bool.self, forKey: .isTemplate) ?? false
        lockedSpans = LockedSpanMath.normalize(try c.decodeIfPresent([LockedSpan].self, forKey: .lockedSpans) ?? [])
    }

    public var displayTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty, trimmedTitle != "Untitled" {
            return trimmedTitle
        }
        if let line = body.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) {
            return String(line.prefix(80))
        }
        return trimmedTitle.isEmpty ? "Untitled" : trimmedTitle
    }

    public var preview: String {
        let flat = body
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if flat.isEmpty { return "Empty note" }
        return String(flat.prefix(120))
    }
}
