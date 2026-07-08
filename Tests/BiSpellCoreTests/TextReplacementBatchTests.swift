import XCTest
@testable import BiSpellCore

final class TextReplacementBatchTests: XCTestCase {
    func testApplyBackToFrontDifferentLengths() {
        // indices: 0123456789...
        let text = "aa X bb YY cc"
        // Replace "YY" (8,2) with "Y" and "X" (3,1) with "XXX"
        let reps = [
            TextReplacement(range: NSRange(location: 3, length: 1), original: "X", replacement: "XXX"),
            TextReplacement(range: NSRange(location: 8, length: 2), original: "YY", replacement: "Y")
        ]
        let out = TextReplacementBatch.apply(text, replacements: reps)
        XCTAssertEqual(out, "aa XXX bb Y cc")
    }

    func testPlanSkipsEmptySuggestions() {
        let m1 = Misspelling(word: "teh", utf16Range: NSRange(location: 0, length: 3), language: .english, suggestions: ["the"])
        let m2 = Misspelling(word: "xyzzy", utf16Range: NSRange(location: 4, length: 5), language: .english, suggestions: [])
        let plan = TextReplacementBatch.plan(misspellings: [m1, m2]) { $0.suggestions.first }
        XCTAssertEqual(plan.replacements.count, 1)
        XCTAssertEqual(plan.skipped, 1)
        XCTAssertEqual(plan.replacements[0].replacement, "the")
    }
}
