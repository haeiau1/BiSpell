import Foundation
import NaturalLanguage

/// Detects TR vs EN for tokens. Reuses one NLLanguageRecognizer (reset per use).
public final class LanguageTagger: @unchecked Sendable {
    public var turkishEnabled: Bool
    public var englishEnabled: Bool
    private let recognizer = NLLanguageRecognizer()
    private let lock = NSLock()

    public init(turkishEnabled: Bool = true, englishEnabled: Bool = true) {
        self.turkishEnabled = turkishEnabled
        self.englishEnabled = englishEnabled
    }

    /// Detect language for a single word using character cues + NL when useful.
    public func detect(word: String, context: String? = nil) -> SpellLanguage {
        if onlyOneLanguageEnabled() {
            return turkishEnabled ? .turkish : .english
        }

        let sample = (context?.isEmpty == false ? context! : word)

        // Strong Turkish orthography signals
        let turkishChars = CharacterSet(charactersIn: "ğüşıöçĞÜŞİÖÇ")
        if sample.unicodeScalars.contains(where: { turkishChars.contains($0) }) {
            return .turkish
        }

        // Common Turkish function words / suffixes heuristics
        let lower = word.lowercased(with: Locale(identifier: "tr_TR"))
        let turkishLexicon: Set<String> = [
            "ve", "bir", "bu", "da", "de", "mi", "mı", "mu", "mü",
            "için", "ile", "ama", "çok", "daha", "gibi", "kadar",
            "var", "yok", "ben", "sen", "biz", "siz", "onlar",
            "şey", "ki", "ne", "nasıl", "neden", "çünkü"
        ]
        if turkishLexicon.contains(lower) {
            return .turkish
        }

        let englishLexicon: Set<String> = [
            "the", "and", "for", "with", "that", "this", "from", "have",
            "was", "were", "are", "is", "not", "you", "your", "what",
            "when", "where", "which", "would", "could", "should"
        ]
        if englishLexicon.contains(word.lowercased()) {
            return .english
        }

        if let context, context.count >= 8 {
            lock.lock()
            defer { lock.unlock() }
            recognizer.reset()
            recognizer.processString(context)
            if let lang = recognizer.dominantLanguage {
                if lang == .turkish { return .turkish }
                if lang == .english { return .english }
            }
        }

        // Default bias: mixed typing → unknown; dict membership resolves later.
        return .unknown
    }

    /// Detect once for a whole document/snippet (cheaper than per-word NL).
    public func detectDocumentLanguage(_ text: String) -> SpellLanguage? {
        guard text.count >= 8 else { return nil }
        if onlyOneLanguageEnabled() {
            return turkishEnabled ? .turkish : .english
        }
        let turkishChars = CharacterSet(charactersIn: "ğüşıöçĞÜŞİÖÇ")
        if text.unicodeScalars.contains(where: { turkishChars.contains($0) }) {
            return .turkish
        }
        lock.lock()
        defer { lock.unlock() }
        recognizer.reset()
        recognizer.processString(text)
        if let lang = recognizer.dominantLanguage {
            if lang == .turkish { return .turkish }
            if lang == .english { return .english }
        }
        return nil
    }

    private func onlyOneLanguageEnabled() -> Bool {
        (turkishEnabled && !englishEnabled) || (!turkishEnabled && englishEnabled)
    }
}
