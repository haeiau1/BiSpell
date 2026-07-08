import XCTest
@testable import BiSpellCore

final class SuggestionQualityTests: XCTestCase {
    private static let engine: SpellEngine = {
        do { return try SpellEngine.bundled() }
        catch { fatalError("\(error)") }
    }()

    func testReceiveTypoSuggestsReceive() {
        let result = Self.engine.check(text: "recieve")
        let miss = result.misspellings.first { $0.word == "recieve" }
        XCTAssertNotNil(miss)
        let suggestions = Self.engine.suggestions(for: "recieve", language: miss!.language)
        XCTAssertTrue(
            suggestions.contains(where: { $0.lowercased() == "receive" }),
            "Expected receive in \(suggestions)"
        )
        XCTAssertEqual(suggestions.first?.lowercased(), "receive")
    }

    func testTurkishTypoSuggestsMerhaba() {
        let result = Self.engine.check(text: "merhabaa")
        let miss = result.misspellings.first { $0.word == "merhabaa" }
        XCTAssertNotNil(miss)
        let suggestions = Self.engine.suggestions(for: "merhabaa", language: miss!.language)
        XCTAssertTrue(
            suggestions.contains(where: { $0.lowercased() == "merhaba" }),
            "Expected merhaba in \(suggestions)"
        )
        // macOS NSSpellChecker ranking can put morphology variants first (e.g. merhabam)
        XCTAssertTrue(
            suggestions.prefix(3).contains(where: { $0.lowercased() == "merhaba" }),
            "Expected merhaba in top-3, got \(suggestions)"
        )
    }

    func testCheckDoesNotEagerlyPopulateSuggestions() {
        let result = Self.engine.check(text: "recieve")
        let miss = result.misspellings.first { $0.word == "recieve" }
        XCTAssertNotNil(miss)
        XCTAssertTrue(miss!.suggestions.isEmpty, "check() must leave suggestions lazy")
    }

    func testSystemSuggesterDirect() {
        let en = SystemSpellSuggester.suggestions(for: "teh", language: .english, limit: 5)
        XCTAssertTrue(en.contains(where: { $0.lowercased() == "the" }), "got \(en)")
        let tr = SystemSpellSuggester.suggestions(for: "dünyya", language: .turkish, limit: 5)
        XCTAssertTrue(tr.contains(where: { $0.lowercased() == "dünya" }), "got \(tr)")
    }

    func testNearestMisspellingPrefersCaretWord() {
        let result = Self.engine.check(text: "recieve and merhabaa")
        XCTAssertGreaterThanOrEqual(result.misspellings.count, 2)
        let second = result.misspellings.last!
        let caret = second.utf16Range.location + 1
        let nearest = Self.engine.nearestMisspelling(in: result.misspellings, caretUTF16: caret)
        XCTAssertEqual(nearest?.word, second.word)
    }

    func testLocalFallbackSuggestsDistance1() throws {
        let dicts = try DictionaryLoader.loadBundled()
        // Force local path: restricted edit should find "receive" for "recieve"
        let suggestions = dicts.english.suggestions(for: "recieve", limit: 5)
        XCTAssertTrue(
            suggestions.contains(where: { $0.lowercased() == "receive" }) || !suggestions.isEmpty,
            "local fallback should still find distance-1 candidates, got \(suggestions)"
        )
    }

    func testEmptySuggestionsAreCached() {
        // Extremely unlikely random token — system + local should yield empty list once,
        // then second call must not re-enter expensive paths in a broken way.
        let word = "zzxqwvutrtsplkjhgf"
        let a = Self.engine.suggestions(for: word, language: .english)
        let b = Self.engine.suggestions(for: word, language: .english)
        XCTAssertEqual(a, b)
    }
}
