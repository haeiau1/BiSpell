import XCTest
@testable import BiSpellCore

final class TokenizerTests: XCTestCase {
    func testTokenizesEnglishAndTurkishWords() {
        let text = "Hello dünya, this is güzel!"
        let tokens = Tokenizer.tokenize(text).map(\.text)
        XCTAssertEqual(tokens, ["Hello", "dünya", "this", "is", "güzel"])
    }

    func testSkipsShortAndNumericAndUrls() {
        XCTAssertTrue(Tokenizer.shouldSkipToken("a"))
        XCTAssertTrue(Tokenizer.shouldSkipToken("42"))
        XCTAssertTrue(Tokenizer.shouldSkipToken("foo_bar"))
        XCTAssertFalse(Tokenizer.shouldSkipToken("hello"))
        XCTAssertFalse(Tokenizer.shouldSkipToken("merhaba"))
    }

    func testSkipsLongIdentifierLikeTokens() {
        XCTAssertTrue(Tokenizer.shouldSkipToken("Abc123def456ghi"))
        XCTAssertFalse(Tokenizer.shouldSkipToken("word2vec"))
    }

    func testUtf16RangesAlignWithNSString() {
        let text = "şeker tea"
        let tokens = Tokenizer.tokenize(text)
        let ns = text as NSString
        XCTAssertEqual(tokens.count, 2)
        XCTAssertEqual(ns.substring(with: tokens[0].utf16Range), "şeker")
        XCTAssertEqual(ns.substring(with: tokens[1].utf16Range), "tea")
    }
}
