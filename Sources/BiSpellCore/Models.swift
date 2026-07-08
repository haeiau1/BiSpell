import Foundation

public enum SpellLanguage: String, Codable, CaseIterable, Sendable {
    case turkish = "tr"
    case english = "en"
    case unknown = "unknown"

    public var displayName: String {
        switch self {
        case .turkish: return "Turkish"
        case .english: return "English"
        case .unknown: return "Unknown"
        }
    }
}

public struct TextToken: Equatable, Sendable {
    public let text: String
    public let range: Range<String.Index>
    public let utf16Range: NSRange

    public init(text: String, range: Range<String.Index>, utf16Range: NSRange) {
        self.text = text
        self.range = range
        self.utf16Range = utf16Range
    }
}

public struct Misspelling: Equatable, Sendable, Identifiable {
    public var id: String { "\(utf16Range.location):\(utf16Range.length):\(word)" }
    public let word: String
    public let utf16Range: NSRange
    public let language: SpellLanguage
    /// Populated lazily when a popup opens (empty after `check()`).
    public var suggestions: [String]

    public init(word: String, utf16Range: NSRange, language: SpellLanguage, suggestions: [String] = []) {
        self.word = word
        self.utf16Range = utf16Range
        self.language = language
        self.suggestions = suggestions
    }
}

public struct SpellCheckResult: Equatable, Sendable {
    public let sourceText: String
    public let misspellings: [Misspelling]
    public let checkedAt: Date

    public init(sourceText: String, misspellings: [Misspelling], checkedAt: Date = Date()) {
        self.sourceText = sourceText
        self.misspellings = misspellings
        self.checkedAt = checkedAt
    }
}

public struct AppSupportSample: Equatable, Sendable, Codable {
    public let appName: String
    public let bundleID: String
    public let canReadValue: Bool
    public let canReadSelection: Bool
    public let canReadBounds: Bool
    public let notes: String
    public let tier: SupportTier

    public init(
        appName: String,
        bundleID: String,
        canReadValue: Bool,
        canReadSelection: Bool,
        canReadBounds: Bool,
        notes: String,
        tier: SupportTier
    ) {
        self.appName = appName
        self.bundleID = bundleID
        self.canReadValue = canReadValue
        self.canReadSelection = canReadSelection
        self.canReadBounds = canReadBounds
        self.notes = notes
        self.tier = tier
    }
}

public enum SupportTier: String, Codable, Sendable {
    case a = "A" // full read + replace expected
    case b = "B" // partial
    case c = "C" // poor / unsupported
}
