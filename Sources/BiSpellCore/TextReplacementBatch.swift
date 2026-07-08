import Foundation

/// A single UTF-16 replacement in a string (range refers to the original string).
public struct TextReplacement: Equatable, Sendable {
    public let range: NSRange
    public let original: String
    public let replacement: String

    public init(range: NSRange, original: String, replacement: String) {
        self.range = range
        self.original = original
        self.replacement = replacement
    }
}

public enum TextReplacementBatch {
    /// Apply replacements **back-to-front** so earlier ranges stay valid.
    public static func apply(_ text: String, replacements: [TextReplacement]) -> String {
        guard !replacements.isEmpty else { return text }
        var ns = text as NSString
        let sorted = replacements.sorted { $0.range.location > $1.range.location }
        for r in sorted {
            let end = r.range.location + r.range.length
            guard r.range.location >= 0, end <= ns.length else { continue }
            ns = ns.replacingCharacters(in: r.range, with: r.replacement) as NSString
        }
        return ns as String
    }

    /// Build top-suggestion replacements from misspellings (caller fills suggestions).
    public static func plan(
        misspellings: [Misspelling],
        topSuggestion: (Misspelling) -> String?
    ) -> (replacements: [TextReplacement], skipped: Int) {
        var reps: [TextReplacement] = []
        var skipped = 0
        for m in misspellings {
            if let s = topSuggestion(m), !s.isEmpty {
                reps.append(TextReplacement(range: m.utf16Range, original: m.word, replacement: s))
            } else {
                skipped += 1
            }
        }
        return (reps, skipped)
    }
}
