import Foundation

/// Persists notes as one JSON file per note under Application Support.
public final class NotesStore: @unchecked Sendable {
    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("BiSpell", isDirectory: true)
                .appendingPathComponent("Notes", isDirectory: true)
            self.directory = base
        }
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    public var notesDirectory: URL { directory }

    public func loadAll() throws -> [Note] {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        var notes: [Note] = []
        for url in files where url.pathExtension.lowercased() == "json" {
            do {
                let data = try Data(contentsOf: url)
                let note = try decoder.decode(Note.self, from: data)
                notes.append(note)
            } catch {
                // Skip corrupt files rather than failing the whole library.
                continue
            }
        }
        return notes.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func save(_ note: Note) throws {
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(note)
        try data.write(to: fileURL(for: note.id), options: .atomic)
    }

    public func delete(id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        let url = fileURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }
}
