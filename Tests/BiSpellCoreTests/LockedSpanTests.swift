import XCTest
@testable import BiSpellCore

final class LockedSpanTests: XCTestCase {
    func testBlocksEditInsideButNotAtEdges() {
        let span = LockedSpan(location: 5, length: 10) // 5..<15
        XCTAssertTrue(span.blocksEdit(in: NSRange(location: 7, length: 0)))
        XCTAssertFalse(span.blocksEdit(in: NSRange(location: 5, length: 0)))
        XCTAssertFalse(span.blocksEdit(in: NSRange(location: 15, length: 0)))
        XCTAssertTrue(span.blocksEdit(in: NSRange(location: 3, length: 5)))
        XCTAssertFalse(span.blocksEdit(in: NSRange(location: 0, length: 5)))
    }

    func testAdjustingShiftsLaterSpans() {
        let spans = [LockedSpan(location: 10, length: 5)]
        let next = LockedSpanMath.adjusting(spans, edited: NSRange(location: 0, length: 0), replacementLength: 3)
        XCTAssertEqual(next.first?.location, 13)
        XCTAssertEqual(next.first?.length, 5)
    }

    func testNoteRoundTripLockedAndTemplate() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BiSpellLock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = NotesStore(directory: dir)
        var note = Note(
            title: "T",
            body: "Hello locked world",
            isTemplate: true,
            lockedSpans: [LockedSpan(location: 6, length: 6)]
        )
        try store.save(note)
        let loaded = try store.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertTrue(loaded[0].isTemplate)
        XCTAssertEqual(loaded[0].lockedSpans.count, 1)
        XCTAssertEqual(loaded[0].lockedSpans[0].location, 6)
    }
}
