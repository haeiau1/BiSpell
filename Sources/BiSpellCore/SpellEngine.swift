import Foundation

public final class SpellEngine: @unchecked Sendable {
    private let turkish: HunspellDictionary
    private let english: HunspellDictionary
    private var tagger: LanguageTagger
    private let lexiconStore: UserLexiconStore
    private let cache = SpellResultCache(capacity: 2_000)

    public var settings: AppSettings

    public init(
        turkish: HunspellDictionary,
        english: HunspellDictionary,
        settings: AppSettings = .default,
        lexiconStore: UserLexiconStore = UserLexiconStore()
    ) {
        self.turkish = turkish
        self.english = english
        self.settings = settings
        self.tagger = LanguageTagger(
            turkishEnabled: settings.turkishEnabled,
            englishEnabled: settings.englishEnabled
        )
        self.lexiconStore = lexiconStore
    }

    public static func bundled(settings: AppSettings = .default) throws -> SpellEngine {
        let dicts = try DictionaryLoader.loadBundled()
        return SpellEngine(turkish: dicts.turkish, english: dicts.english, settings: settings)
    }

    public func updateSettings(_ settings: AppSettings) {
        self.settings = settings
        self.tagger = LanguageTagger(
            turkishEnabled: settings.turkishEnabled,
            englishEnabled: settings.englishEnabled
        )
    }

    public var lexicon: UserLexicon { lexiconStore.current() }

    public func addToDictionary(_ word: String) {
        lexiconStore.update { $0.addWord(word) }
        cache.removeAll()
    }

    public func ignoreWord(_ word: String) {
        lexiconStore.update { $0.ignoreOnce(word) }
    }

    public func ignoreWord(_ word: String, inApp bundleID: String) {
        lexiconStore.update { $0.ignoreInApp(word, bundleID: bundleID) }
    }

    public func removeFromDictionary(_ word: String) {
        lexiconStore.update { $0.removeWord(word) }
        cache.removeAll()
    }

    public func unignoreWord(_ word: String) {
        lexiconStore.update { $0.unignore(word) }
    }

    /// Markers only: correctness + language. Suggestions are empty until `suggestions(for:language:)`.
    public func check(
        text: String,
        caretUTF16: Int? = nil,
        bundleID: String? = nil,
        nearCaretOnly: Bool = false,
        windowRadius: Int = 120
    ) -> SpellCheckResult {
        guard settings.isEnabled else {
            return SpellCheckResult(sourceText: text, misspellings: [])
        }
        guard settings.turkishEnabled || settings.englishEnabled else {
            return SpellCheckResult(sourceText: text, misspellings: [])
        }

        let tokens = Tokenizer.tokenize(text)
        let lexicon = lexiconStore.current()
        var misspellings: [Misspelling] = []
        let documentLang = tagger.detectDocumentLanguage(text)

        let focusRange: NSRange? = {
            guard nearCaretOnly, let caret = caretUTF16 else { return nil }
            let nsLen = (text as NSString).length
            let start = max(0, caret - windowRadius)
            let end = min(nsLen, caret + windowRadius)
            return NSRange(location: start, length: max(0, end - start))
        }()

        for token in tokens {
            if token.text.count < settings.minWordLength { continue }
            if Tokenizer.shouldSkipToken(token.text) { continue }
            if let focusRange {
                let inter = NSIntersectionRange(focusRange, token.utf16Range)
                if inter.length == 0 { continue }
            }
            if lexicon.ignores(token.text, inApp: bundleID) { continue }

            let context = contextSnippet(text: text, around: token.utf16Range, radius: 40)
            let lang = resolveLanguage(for: token.text, context: context, documentLang: documentLang)

            let (isCorrect, resolvedLang) = evaluateCorrectness(word: token.text, language: lang)
            if !isCorrect {
                misspellings.append(
                    Misspelling(
                        word: token.text,
                        utf16Range: token.utf16Range,
                        language: resolvedLang,
                        suggestions: []
                    )
                )
            }
        }

        return SpellCheckResult(sourceText: text, misspellings: misspellings)
    }

    /// Public suggestion API — call just before showing a popup.
    public func suggestions(for word: String, language: SpellLanguage) -> [String] {
        let key = cacheKey(word: word, language: language)
        if let hit = cache.get(key), hit.suggestionsComputed {
            return Array(hit.suggestions.prefix(settings.maxSuggestions))
        }

        let limit = settings.maxSuggestions
        let system = SystemSpellSuggester.suggestions(for: word, language: language, limit: limit)
        let list: [String]
        if !system.isEmpty {
            list = system
        } else {
            switch language {
            case .turkish:
                list = turkish.suggestions(for: word, limit: limit)
            case .english:
                list = english.suggestions(for: word, limit: limit)
            case .unknown:
                let en = english.suggestions(for: word, limit: limit)
                list = en.isEmpty ? turkish.suggestions(for: word, limit: limit) : en
            }
        }

        let correct = isCorrectLocalOrSystem(word, language: language)
        cache.set(
            key,
            value: CacheEntry(isCorrect: correct, suggestions: list, suggestionsComputed: true)
        )
        return list
    }

    /// Fill suggestions on a misspelling. For language-ambiguous words, pick TR vs EN by
    /// top-suggestion edit distance (restores pre-1.4 ranking without doing it on every tick).
    public func withSuggestions(_ misspelling: Misspelling) -> Misspelling {
        var copy = misspelling
        if !copy.suggestions.isEmpty { return copy }

        if shouldDisambiguateLanguage(copy.language) {
            let en = settings.englishEnabled ? suggestions(for: copy.word, language: .english) : []
            let tr = settings.turkishEnabled ? suggestions(for: copy.word, language: .turkish) : []
            if !en.isEmpty && tr.isEmpty {
                copy = Misspelling(word: copy.word, utf16Range: copy.utf16Range, language: .english, suggestions: en)
            } else if !tr.isEmpty && en.isEmpty {
                copy = Misspelling(word: copy.word, utf16Range: copy.utf16Range, language: .turkish, suggestions: tr)
            } else if !en.isEmpty && !tr.isEmpty {
                let enDist = editDistance(copy.word, en[0])
                let trDist = editDistance(copy.word, tr[0])
                if trDist < enDist {
                    copy = Misspelling(word: copy.word, utf16Range: copy.utf16Range, language: .turkish, suggestions: tr)
                } else {
                    copy = Misspelling(word: copy.word, utf16Range: copy.utf16Range, language: .english, suggestions: en)
                }
            } else {
                copy.suggestions = suggestions(for: copy.word, language: copy.language)
            }
        } else {
            copy.suggestions = suggestions(for: copy.word, language: copy.language)
        }
        return copy
    }

    /// Misspelling nearest to caret (prefers the word the user is typing / just finished).
    public func nearestMisspelling(in misspellings: [Misspelling], caretUTF16: Int?) -> Misspelling? {
        guard !misspellings.isEmpty else { return nil }
        guard let caret = caretUTF16 else { return misspellings.first }

        if let inside = misspellings.first(where: {
            caret >= $0.utf16Range.location && caret <= $0.utf16Range.location + $0.utf16Range.length
        }) {
            return inside
        }

        if let justAfter = misspellings
            .filter({ caret >= $0.utf16Range.location + $0.utf16Range.length })
            .min(by: {
                let da = caret - ($0.utf16Range.location + $0.utf16Range.length)
                let db = caret - ($1.utf16Range.location + $1.utf16Range.length)
                return da < db
            }),
           caret - (justAfter.utf16Range.location + justAfter.utf16Range.length) <= 2 {
            return justAfter
        }

        return misspellings.min(by: {
            let mid0 = $0.utf16Range.location + $0.utf16Range.length / 2
            let mid1 = $1.utf16Range.location + $1.utf16Range.length / 2
            return abs(mid0 - caret) < abs(mid1 - caret)
        })
    }

    private func shouldDisambiguateLanguage(_ language: SpellLanguage) -> Bool {
        guard settings.turkishEnabled && settings.englishEnabled else { return false }
        // Only when language is unresolved — avoids dual AppleSpell calls for clear TR/EN words.
        return language == .unknown
    }

    private func resolveLanguage(for word: String, context: String, documentLang: SpellLanguage?) -> SpellLanguage {
        let detected = tagger.detect(word: word, context: context)
        if detected != .unknown { return detected }
        if settings.turkishEnabled && isCorrectCached(word, language: .turkish) { return .turkish }
        if settings.englishEnabled && isCorrectCached(word, language: .english) { return .english }
        if let documentLang, documentLang != .unknown { return documentLang }
        return detected
    }

    private func evaluateCorrectness(word: String, language: SpellLanguage) -> (Bool, SpellLanguage) {
        switch language {
        case .turkish:
            if !settings.turkishEnabled { return evaluateBothCorrectness(word) }
            if isCorrectCached(word, language: .turkish) { return (true, .turkish) }
            return (false, .turkish)
        case .english:
            if !settings.englishEnabled { return evaluateBothCorrectness(word) }
            if isCorrectCached(word, language: .english) { return (true, .english) }
            return (false, .english)
        case .unknown:
            return evaluateBothCorrectness(word)
        }
    }

    private func evaluateBothCorrectness(_ word: String) -> (Bool, SpellLanguage) {
        let trOK = settings.turkishEnabled && isCorrectCached(word, language: .turkish)
        let enOK = settings.englishEnabled && isCorrectCached(word, language: .english)
        if trOK { return (true, .turkish) }
        if enOK { return (true, .english) }

        // Stay cheap on the typing path. TR/EN ranking for suggestions is deferred to
        // withSuggestions() (popup only) via shouldDisambiguateLanguage.
        if settings.turkishEnabled && settings.englishEnabled {
            return (false, .unknown)
        }
        let lang: SpellLanguage = settings.englishEnabled ? .english : .turkish
        return (false, lang)
    }

    private func isCorrectCached(_ word: String, language: SpellLanguage) -> Bool {
        let key = cacheKey(word: word, language: language)
        if let hit = cache.get(key) {
            return hit.isCorrect
        }
        let ok = isCorrectLocalOrSystem(word, language: language)
        cache.set(
            key,
            value: CacheEntry(isCorrect: ok, suggestions: [], suggestionsComputed: false)
        )
        return ok
    }

    private func isCorrectLocalOrSystem(_ word: String, language: SpellLanguage) -> Bool {
        switch language {
        case .turkish:
            if turkish.contains(word) { return true }
            return SystemSpellSuggester.isCorrect(word, language: .turkish)
        case .english:
            if english.contains(word) { return true }
            return SystemSpellSuggester.isCorrect(word, language: .english)
        case .unknown:
            return false
        }
    }

    private func cacheKey(word: String, language: SpellLanguage) -> String {
        "\(language.rawValue)|\(word)"
    }

    private func editDistance(_ a: String, _ b: String) -> Int {
        let A = Array(a.lowercased()), B = Array(b.lowercased())
        let n = A.count, m = B.count
        if n == 0 { return m }
        if m == 0 { return n }
        var prev = Array(0...m)
        var cur = Array(repeating: 0, count: m + 1)
        for i in 1...n {
            cur[0] = i
            for j in 1...m {
                let cost = A[i - 1] == B[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            prev = cur
        }
        return prev[m]
    }

    private func contextSnippet(text: String, around range: NSRange, radius: Int) -> String {
        let ns = text as NSString
        let start = max(0, range.location - radius)
        let end = min(ns.length, range.location + range.length + radius)
        return ns.substring(with: NSRange(location: start, length: end - start))
    }
}

// MARK: - LRU cache

private struct CacheEntry {
    var isCorrect: Bool
    var suggestions: [String]
    /// True once `suggestions(for:)` has run (even if the list is empty).
    var suggestionsComputed: Bool
}

private final class SpellResultCache: @unchecked Sendable {
    private let capacity: Int
    private var order: [String] = []
    private var map: [String: CacheEntry] = [:]
    private let lock = NSLock()

    init(capacity: Int) {
        self.capacity = max(16, capacity)
    }

    func get(_ key: String) -> CacheEntry? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = map[key] else { return nil }
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
            order.append(key)
        }
        return value
    }

    func set(_ key: String, value: CacheEntry) {
        lock.lock()
        defer { lock.unlock() }
        if map[key] != nil {
            map[key] = merge(existing: map[key]!, incoming: value)
            if let idx = order.firstIndex(of: key) {
                order.remove(at: idx)
                order.append(key)
            }
            return
        }
        map[key] = value
        order.append(key)
        while order.count > capacity {
            let old = order.removeFirst()
            map.removeValue(forKey: old)
        }
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        map.removeAll()
        order.removeAll()
    }

    private func merge(existing: CacheEntry, incoming: CacheEntry) -> CacheEntry {
        CacheEntry(
            isCorrect: incoming.isCorrect,
            suggestions: incoming.suggestionsComputed ? incoming.suggestions : existing.suggestions,
            suggestionsComputed: existing.suggestionsComputed || incoming.suggestionsComputed
        )
    }
}
