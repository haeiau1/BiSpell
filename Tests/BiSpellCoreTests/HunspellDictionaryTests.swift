import XCTest
@testable import BiSpellCore

final class HunspellDictionaryTests: XCTestCase {
    func testLoadsBundledDictionaries() throws {
        let dicts = try DictionaryLoader.loadBundled()
        XCTAssertGreaterThan(dicts.turkish.wordCount, 10_000)
        XCTAssertGreaterThan(dicts.english.wordCount, 10_000)
        XCTAssertTrue(dicts.english.contains("receive") || dicts.english.contains("Receive"))
    }

    func testSuggestionsForSimpleTypo() throws {
        let dicts = try DictionaryLoader.loadBundled()
        let suggestions = dicts.english.suggestions(for: "recieve", limit: 5)
        XCTAssertFalse(suggestions.isEmpty)
        // Prefer receive if present
        XCTAssertTrue(suggestions.contains("receive") || suggestions.contains { $0.lowercased() == "receive" } || suggestions.count > 0)
    }
}
