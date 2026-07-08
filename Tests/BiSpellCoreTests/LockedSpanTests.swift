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

    func testUnlockedSegmentsEmptyWhenFullyLocked() {
        let spans = [LockedSpan(location: 0, length: 10)]
        let segs = LockedSpanMath.unlockedSegments(of: NSRange(location: 0, length: 10), spans: spans)
        XCTAssertTrue(segs.isEmpty)
    }

    func testUnlockedSegmentsWholeRangeWhenNoOverlap() {
        let spans = [LockedSpan(location: 20, length: 5)]
        let segs = LockedSpanMath.unlockedSegments(of: NSRange(location: 0, length: 10), spans: spans)
        XCTAssertEqual(segs, [NSRange(location: 0, length: 10)])
    }

    func testUnlockedSegmentsMultiSegment() {
        // 0..3 unlocked, 3..6 locked, 6..9 unlocked, 9..12 locked, 12..15 unlocked
        let spans = [
            LockedSpan(location: 3, length: 3),
            LockedSpan(location: 9, length: 3)
        ]
        let segs = LockedSpanMath.unlockedSegments(of: NSRange(location: 0, length: 15), spans: spans)
        XCTAssertEqual(segs.count, 3)
        XCTAssertEqual(segs[0], NSRange(location: 0, length: 3))
        XCTAssertEqual(segs[1], NSRange(location: 6, length: 3))
        XCTAssertEqual(segs[2], NSRange(location: 12, length: 3))
    }

    func testUnlockedSegmentsAdjacentSpanEdges() {
        let spans = [LockedSpan(location: 5, length: 5)] // 5..<10
        let segs = LockedSpanMath.unlockedSegments(of: NSRange(location: 0, length: 15), spans: spans)
        XCTAssertEqual(segs, [
            NSRange(location: 0, length: 5),
            NSRange(location: 10, length: 5)
        ])
    }

    func testAdjacentLocksDoNotMerge() {
        // After deleting a single space between two locks, spans become adjacent — must stay separate.
        let spans = [
            LockedSpan(location: 0, length: 3),
            LockedSpan(location: 3, length: 3)
        ]
        let norm = LockedSpanMath.normalize(spans)
        XCTAssertEqual(norm.count, 2, "Adjacent locks must not merge into one block")
        XCTAssertEqual(norm[0].location, 0)
        XCTAssertEqual(norm[0].length, 3)
        XCTAssertEqual(norm[1].location, 3)
        XCTAssertEqual(norm[1].length, 3)
        // Caret between them (at 3) is at the edge of both — insertion allowed.
        XCTAssertFalse(LockedSpanMath.anyBlocks(norm, edit: NSRange(location: 3, length: 0)))
    }

    func testApplyingDeletionsShiftsLocks() {
        // "AAA LOCK BBB" — lock at 4 len 4 after "AAA "
        let spans = [LockedSpan(location: 4, length: 4)]
        let unlocked = LockedSpanMath.unlockedSegments(
            of: NSRange(location: 0, length: 11),
            spans: spans
        )
        // Assume text length 11: AAA_LOCK_BB style
        let next = LockedSpanMath.applyingDeletions(spans, segments: unlocked)
        // After deleting unlocked parts back-to-front, lock should sit at 0
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(next[0].location, 0)
        XCTAssertEqual(next[0].length, 4)
    }

    func testNoteRoundTripLockedAndTemplate() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BiSpellLock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = NotesStore(directory: dir)
        let note = Note(
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
