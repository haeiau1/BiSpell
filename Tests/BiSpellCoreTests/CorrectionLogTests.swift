import XCTest
@testable import BiSpellCore

final class CorrectionLogTests: XCTestCase {
    private var dir: URL!
    private var store: CorrectionLogStore!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BiSpellCorr-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = CorrectionLogStore(filename: "corrections.json", baseDirectory: dir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    func testRecordsWrongAndCorrectWithCount() throws {
        XCTAssertNotNil(store.record(wrong: "recieve", correct: "receive"))
        XCTAssertNotNil(store.record(wrong: "recieve", correct: "receive"))
        XCTAssertNotNil(store.record(wrong: "teh", correct: "the"))

        let snap = store.snapshot()
        XCTAssertEqual(snap.corrections.count, 2)
        let recieve = snap.corrections.first { $0.wrong.lowercased() == "recieve" }
        XCTAssertEqual(recieve?.correct, "receive")
        XCTAssertEqual(recieve?.count, 2)

        // Reload from disk
        let reloaded = CorrectionLogStore(filename: "corrections.json", baseDirectory: dir)
        let again = reloaded.snapshot()
        XCTAssertEqual(again.corrections.count, 2)
        XCTAssertEqual(again.corrections.first { $0.wrong.lowercased() == "recieve" }?.count, 2)
    }

    func testSkipsIdenticalWrongAndCorrect() {
        XCTAssertNil(store.record(wrong: "Hello", correct: "hello"))
        XCTAssertTrue(store.snapshot().corrections.isEmpty)
    }
}
