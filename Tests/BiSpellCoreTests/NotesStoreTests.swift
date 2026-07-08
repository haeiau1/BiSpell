import XCTest
@testable import BiSpellCore

final class NotesStoreTests: XCTestCase {
    private var dir: URL!
    private var store: NotesStore!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BiSpellNotesTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = NotesStore(directory: dir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    func testSaveLoadDelete() throws {
        var note = Note(title: "Hello", body: "World")
        try store.save(note)
        var all = try store.loadAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].title, "Hello")
        XCTAssertEqual(all[0].body, "World")

        note.body = "Updated"
        note.updatedAt = Date()
        try store.save(note)
        all = try store.loadAll()
        XCTAssertEqual(all[0].body, "Updated")

        try store.delete(id: note.id)
        all = try store.loadAll()
        XCTAssertTrue(all.isEmpty)
    }

    func testDisplayTitleFallsBackToBody() {
        let note = Note(title: "Untitled", body: "First line\nSecond")
        XCTAssertEqual(note.displayTitle, "First line")
    }
}
