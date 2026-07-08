import XCTest
@testable import BiSpellCore

final class UserLexiconTests: XCTestCase {
    func testAddAndIgnore() {
        var lex = UserLexicon()
        XCTAssertFalse(lex.accepts("FooBar"))
        lex.addWord("FooBar")
        XCTAssertTrue(lex.accepts("FooBar"))
        XCTAssertTrue(lex.accepts("foobar"))
        lex.ignoreInApp("Baz", bundleID: "com.example.app")
        XCTAssertTrue(lex.ignores("Baz", inApp: "com.example.app"))
        XCTAssertFalse(lex.ignores("Baz", inApp: "com.other"))
    }

    func testRemoveWordIsCaseInsensitive() {
        var lex = UserLexicon()
        lex.addWord("FooBar")
        lex.removeWord("foobar")
        XCTAssertFalse(lex.accepts("FooBar"))
    }

    func testUnignoreClearsGlobalAndPerAppEntries() {
        var lex = UserLexicon()
        lex.ignoreOnce("Baz")
        lex.ignoreInApp("Baz", bundleID: "com.example.app")
        lex.ignoreInApp("Qux", bundleID: "com.example.app")
        lex.unignore("baz")
        XCTAssertFalse(lex.ignores("Baz", inApp: nil))
        XCTAssertFalse(lex.ignores("Baz", inApp: "com.example.app"))
        XCTAssertTrue(lex.ignores("Qux", inApp: "com.example.app"))
    }
}
