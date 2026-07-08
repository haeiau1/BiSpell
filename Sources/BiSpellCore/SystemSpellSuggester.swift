import AppKit
import Foundation

/// High-quality offline suggestions via macOS NSSpellChecker (TR/EN on device).
public enum SystemSpellSuggester {
    public static func suggestions(for word: String, language: SpellLanguage, limit: Int = 5) -> [String] {
        guard word.count >= 2 else { return [] }
        let checker = NSSpellChecker.shared
        let range = NSRange(location: 0, length: (word as NSString).length)
        var results: [String] = []

        for code in languageCodes(for: language) {
            if let guesses = checker.guesses(
                forWordRange: range,
                in: word,
                language: code,
                inSpellDocumentWithTag: 0
            ) {
                for g in guesses where !g.isEmpty {
                    if !results.contains(where: { $0.caseInsensitiveCompare(g) == .orderedSame }) {
                        results.append(g)
                    }
                    if results.count >= limit { return results }
                }
            }
        }
        return results
    }

    /// Returns true if the system checker considers the word correctly spelled for the language.
    public static func isCorrect(_ word: String, language: SpellLanguage) -> Bool {
        let checker = NSSpellChecker.shared
        for code in languageCodes(for: language) {
            var wordCount: Int = 0
            let miss = checker.checkSpelling(
                of: word,
                startingAt: 0,
                language: code,
                wrap: false,
                inSpellDocumentWithTag: 0,
                wordCount: &wordCount
            )
            if miss.location == NSNotFound {
                return true
            }
        }
        return false
    }

    private static func languageCodes(for language: SpellLanguage) -> [String] {
        switch language {
        case .turkish:
            return ["tr_TR", "tr"]
        case .english:
            return ["en", "en_US"]
        case .unknown:
            return ["en", "tr_TR", "tr"]
        }
    }
}
