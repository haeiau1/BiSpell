import XCTest
@testable import BiSpellCore

final class LanguageTaggerTests: XCTestCase {
    func testDetectsTurkishCharacters() {
        let tagger = LanguageTagger()
        XCTAssertEqual(tagger.detect(word: "güzel"), .turkish)
        XCTAssertEqual(tagger.detect(word: "şeker"), .turkish)
    }

    func testDetectsEnglishFunctionWords() {
        let tagger = LanguageTagger()
        XCTAssertEqual(tagger.detect(word: "the"), .english)
        XCTAssertEqual(tagger.detect(word: "because"), .unknown) // not in small list
        XCTAssertEqual(tagger.detect(word: "and"), .english)
    }

    func testSingleLanguageMode() {
        let trOnly = LanguageTagger(turkishEnabled: true, englishEnabled: false)
        XCTAssertEqual(trOnly.detect(word: "hello"), .turkish)
        let enOnly = LanguageTagger(turkishEnabled: false, englishEnabled: true)
        XCTAssertEqual(enOnly.detect(word: "merhaba"), .english)
    }
}
