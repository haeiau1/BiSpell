import Foundation

/// Loads Hunspell-format `.dic` word lists (stems; affix flags stripped).
/// Membership uses case-folding plus lightweight suffix stripping.
/// Local suggestions are a ranked fallback; prefer SystemSpellSuggester when available.
///
/// Memory: no SymSpell delete map. Fallback suggestions use distance-1 restricted edits
/// looked up in a single lowercased entry table.
public final class HunspellDictionary: @unchecked Sendable {
    public let language: SpellLanguage

    /// lowercased key → (canonical form only if it differs from the key, load order)
    private struct Entry {
        var canonical: String?
        var order: Int32
    }

    private let entries: [String: Entry]
    public let wordCount: Int

    public init(language: SpellLanguage, dictionaryURL: URL) throws {
        self.language = language
        let data = try String(contentsOf: dictionaryURL, encoding: .utf8)
        var map: [String: Entry] = [:]
        var firstLine = true
        var order: Int32 = 0

        for line in data.split(whereSeparator: \.isNewline) {
            let raw = line.trimmingCharacters(in: .whitespaces)
            if raw.isEmpty || raw.hasPrefix("#") { continue }
            if firstLine {
                firstLine = false
                if Int(raw) != nil { continue }
            }
            let stem = raw.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first
                .map(String.init)?
                .split(separator: "\t").first
                .map(String.init) ?? raw
            let word = stem.trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty else { continue }
            let lower = Self.normalize(word, language: language)
            if map[lower] == nil {
                let canonical: String? = (word == lower) ? nil : word
                map[lower] = Entry(canonical: canonical, order: order)
                order += 1
            }
        }

        self.entries = map
        self.wordCount = map.count
    }

    public func contains(_ word: String) -> Bool {
        let lower = Self.normalize(word, language: language)
        if entries[lower] != nil { return true }
        for variant in Self.stemCandidates(lower, language: language) {
            if entries[variant] != nil { return true }
        }
        return false
    }

    public func suggestions(for word: String, limit: Int = 5) -> [String] {
        if contains(word) { return [] }
        let lower = Self.normalize(word, language: language)
        guard lower.count >= 2 else { return [] }

        var best: [String: Int] = [:]

        func consider(_ canonical: String) {
            let candLower = Self.normalize(canonical, language: language)
            let dist = Self.damerauLevenshtein(lower, candLower, limit: 1)
            guard dist <= 1 else { return }

            let lenDiff = abs(candLower.count - lower.count)
            guard lenDiff <= 2 else { return }

            let sameStart = (candLower.first == lower.first) ? 0 : 8
            let prefixBonus = -min(Self.commonPrefixLength(lower, candLower), 4)
            let order = entries[candLower]?.order ?? 50_000
            let freqPenalty = Int(min(order, 50_000) / 500)
            let score = dist * 100 + lenDiff * 15 + sameStart + freqPenalty + prefixBonus

            if let prev = best[canonical], prev <= score { return }
            if let existing = best.first(where: { Self.normalize($0.key, language: language) == candLower }),
               existing.value <= score {
                return
            }
            best[canonical] = score
        }

        // Distance-1 candidates via restricted edits → dictionary lookup (no delete index).
        for edit in Self.generateRestrictedEdits(lower) {
            if let entry = entries[edit] {
                consider(entry.canonical ?? edit)
            }
        }

        return best
            .sorted { $0.value < $1.value }
            .prefix(limit)
            .map(\.key)
    }

    public static func normalize(_ word: String, language: SpellLanguage) -> String {
        switch language {
        case .turkish:
            return word.lowercased(with: Locale(identifier: "tr_TR"))
        case .english, .unknown:
            return word.lowercased(with: Locale(identifier: "en_US"))
        }
    }

    static func stemCandidates(_ lower: String, language: SpellLanguage) -> [String] {
        var out: [String] = []
        func add(_ s: String) {
            if s.count >= 2, !out.contains(s) { out.append(s) }
        }

        switch language {
        case .english, .unknown:
            let suffixes = ["'s", "s", "es", "ed", "ing", "ly", "er", "est", "ness", "ment", "tion", "able", "ible"]
            var current = lower
            for _ in 0..<3 {
                var stripped = false
                for suf in suffixes where current.count > suf.count + 2 && current.hasSuffix(suf) {
                    let base = String(current.dropLast(suf.count))
                    add(base)
                    if suf == "es" { add(base + "e") }
                    if suf == "ing" {
                        add(base)
                        add(base + "e")
                        if base.count > 2, base.last == base.dropLast().last {
                            add(String(base.dropLast()))
                        }
                    }
                    if suf == "ed" {
                        add(base)
                        add(base + "e")
                    }
                    current = base
                    stripped = true
                    break
                }
                if !stripped { break }
            }
            if lower.hasSuffix("ies"), lower.count > 4 {
                add(String(lower.dropLast(3)) + "y")
            }

        case .turkish:
            let suffixes = [
                "makta", "mekte", "acak", "ecek", "iyor", "uyor", "üyor", "ıyor",
                "lar", "ler", "den", "dan", "ten", "tan", "nin", "nın", "nun", "nün",
                "sin", "sın", "sun", "sün", "yiz", "yız", "yuz", "yüz",
                "dir", "dır", "dur", "dür", "tir", "tır", "tur", "tür",
                "in", "ın", "un", "ün", "im", "ım", "um", "üm",
                "de", "da", "te", "ta", "ki", "mı", "mi", "mu", "mü"
            ]
            var current = lower
            for _ in 0..<4 {
                var stripped = false
                for suf in suffixes where current.count > suf.count + 2 && current.hasSuffix(suf) {
                    let base = String(current.dropLast(suf.count))
                    add(base)
                    current = base
                    stripped = true
                    break
                }
                if !stripped { break }
            }
        }
        return out
    }

    /// Deletes, transposes, replaces, and short inserts — then dictionary membership filters.
    private static func generateRestrictedEdits(_ word: String) -> Set<String> {
        let alphabet: [Character] = Array("abcdefghijklmnopqrstuvwxyzçğıöşü")
        var result = Set<String>()
        let chars = Array(word)

        for i in chars.indices {
            var c = chars
            c.remove(at: i)
            result.insert(String(c))
        }
        if chars.count > 1 {
            for i in 0..<(chars.count - 1) {
                var c = chars
                c.swapAt(i, i + 1)
                result.insert(String(c))
            }
        }
        for i in chars.indices {
            for L in alphabet where L != chars[i] {
                var c = chars
                c[i] = L
                result.insert(String(c))
            }
        }
        if chars.count <= 9 {
            for i in 0...chars.count {
                for L in alphabet {
                    var c = chars
                    c.insert(L, at: i)
                    result.insert(String(c))
                }
            }
        }
        return result
    }

    private static func commonPrefixLength(_ a: String, _ b: String) -> Int {
        let A = Array(a), B = Array(b)
        var i = 0
        while i < A.count, i < B.count, A[i] == B[i] { i += 1 }
        return i
    }

    /// Damerau–Levenshtein (includes transposition) with early exit.
    private static func damerauLevenshtein(_ a: String, _ b: String, limit: Int) -> Int {
        let A = Array(a), B = Array(b)
        let n = A.count, m = B.count
        if abs(n - m) > limit { return limit + 1 }
        if n == 0 { return m }
        if m == 0 { return n }

        var prevPrev = Array(repeating: 0, count: m + 1)
        var prev = Array(0...m)
        var cur = Array(repeating: 0, count: m + 1)

        for i in 1...n {
            cur[0] = i
            var rowMin = cur[0]
            for j in 1...m {
                let cost = A[i - 1] == B[j - 1] ? 0 : 1
                var val = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                if i > 1, j > 1, A[i - 1] == B[j - 2], A[i - 2] == B[j - 1] {
                    val = min(val, prevPrev[j - 2] + 1)
                }
                cur[j] = val
                rowMin = min(rowMin, val)
            }
            if rowMin > limit { return limit + 1 }
            prevPrev = prev
            prev = cur
            cur = Array(repeating: 0, count: m + 1)
        }
        return prev[m]
    }
}

public enum DictionaryLoader {
    public static func bundledURL(name: String, ext: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Dictionaries")
            ?? Bundle.module.url(forResource: name, withExtension: ext)
    }

    public static func loadBundled() throws -> (turkish: HunspellDictionary, english: HunspellDictionary) {
        guard let trURL = bundledURL(name: "tr", ext: "dic") else {
            throw DictionaryError.missingResource("tr.dic")
        }
        guard let enURL = bundledURL(name: "en_US", ext: "dic") else {
            throw DictionaryError.missingResource("en_US.dic")
        }
        let tr = try HunspellDictionary(language: .turkish, dictionaryURL: trURL)
        let en = try HunspellDictionary(language: .english, dictionaryURL: enURL)
        return (tr, en)
    }
}

public enum DictionaryError: Error, LocalizedError {
    case missingResource(String)

    public var errorDescription: String? {
        switch self {
        case .missingResource(let name): return "Missing dictionary resource: \(name)"
        }
    }
}
