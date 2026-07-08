import XCTest
@testable import BiSpellCore

final class SpellEngineTests: XCTestCase {
    private static let shared: SpellEngine = {
        do { return try SpellEngine.bundled() }
        catch { fatalError("dict load failed: \(error)") }
    }()

    private var engine: SpellEngine { Self.shared }

    override func setUp() {
        super.setUp()
        engine.updateSettings(.default)
    }

    func testEnglishTypoIsFlaggedWithSuggestion() {
        let result = engine.check(text: "I recieve mail today")
        let words = result.misspellings.map(\.word)
        XCTAssertTrue(words.contains("recieve"), "Expected recieve to be flagged, got \(words)")
        let miss = result.misspellings.first { $0.word == "recieve" }
        XCTAssertNotNil(miss)
        let suggestions = engine.suggestions(for: miss!.word, language: miss!.language)
        XCTAssertFalse(suggestions.isEmpty, "Expected suggestions for recieve")
    }

    func testCorrectEnglishReceiveNotFlagged() {
        let result = engine.check(text: "I receive mail today")
        XCTAssertFalse(result.misspellings.map(\.word).contains("receive"))
    }

    func testCorrectEnglishPluralViaStemming() {
        let result = engine.check(text: "messages")
        XCTAssertFalse(
            result.misspellings.map(\.word).contains("messages"),
            "messages should be accepted via stem rules; flags=\(result.misspellings)"
        )
    }

    func testTurkishTypoIsFlagged() {
        let result = engine.check(text: "merhabaa ve dünyya")
        let words = result.misspellings.map(\.word)
        XCTAssertTrue(words.contains("merhabaa"), "Expected merhabaa flagged, got \(words)")
        XCTAssertTrue(words.contains("dünyya"), "Expected dünyya flagged, got \(words)")
    }

    func testTurkishInflectedMayNeedLexiconOrStem() {
        // Complex agglutination may still false-positive; user can Add to Dictionary.
        let result = engine.check(text: "kitaplar")
        // "kitaplar" should pass via lar suffix if "kitap" in dict
        XCTAssertFalse(result.misspellings.map(\.word).contains("kitaplar"),
                       "kitaplar should stem to kitap; got \(result.misspellings)")
    }

    func testCorrectTurkishCommonWord() {
        let result = engine.check(text: "merhaba dünya")
        let words = Set(result.misspellings.map { $0.word.lowercased() })
        XCTAssertFalse(words.contains("merhaba"))
    }

    func testUserLexiconAcceptsCustomWord() {
        engine.addToDictionary("BiSpellXYZ")
        let result = engine.check(text: "BiSpellXYZ is cool")
        XCTAssertFalse(result.misspellings.map(\.word).contains("BiSpellXYZ"))
    }

    func testMixedSentenceFindsEnglishTypo() {
        let result = engine.check(text: "Bugün recieve etmek istiyorum")
        XCTAssertTrue(result.misspellings.map(\.word).contains("recieve"))
    }

    func testDisabledEngineReturnsNoIssues() {
        var s = AppSettings.default
        s.isEnabled = false
        engine.updateSettings(s)
        let result = engine.check(text: "recieve merhabaa")
        XCTAssertTrue(result.misspellings.isEmpty)
    }

    func testNearCaretOnlySkipsFarTokens() {
        let text = "recieve " + String(repeating: "word ", count: 50) + "teh"
        let caret = (text as NSString).length - 1
        let result = engine.check(text: text, caretUTF16: caret, nearCaretOnly: true, windowRadius: 20)
        let words = result.misspellings.map(\.word)
        XCTAssertFalse(words.contains("recieve"))
    }
}
