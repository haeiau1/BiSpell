import Foundation

/// One learned mapping: wrong spelling → preferred correction.
public struct CorrectionRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String { Self.makeID(wrong: wrong, correct: correct) }
    public var wrong: String
    public var correct: String
    public var count: Int
    public var firstCorrectedAt: Date
    public var lastCorrectedAt: Date

    public init(
        wrong: String,
        correct: String,
        count: Int = 1,
        firstCorrectedAt: Date = Date(),
        lastCorrectedAt: Date = Date()
    ) {
        self.wrong = wrong
        self.correct = correct
        self.count = count
        self.firstCorrectedAt = firstCorrectedAt
        self.lastCorrectedAt = lastCorrectedAt
    }

    public static func makeID(wrong: String, correct: String) -> String {
        "\(wrong.lowercased())→\(correct.lowercased())"
    }
}

public struct CorrectionLogFile: Codable, Equatable, Sendable {
    public var version: Int
    public var corrections: [CorrectionRecord]

    public static let empty = CorrectionLogFile(version: 1, corrections: [])

    public init(version: Int = 1, corrections: [CorrectionRecord] = []) {
        self.version = version
        self.corrections = corrections
    }
}

/// Persists wrong→correct pairs (with counts) for later suggestion ranking.
public final class CorrectionLogStore: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "BiSpell.CorrectionLogStore")
    private var file: CorrectionLogFile
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(filename: String = "corrections.json", baseDirectory: URL? = nil) {
        let dir = baseDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BiSpell", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent(filename)
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601

        if let data = try? Data(contentsOf: url),
           let decoded = try? decoder.decode(CorrectionLogFile.self, from: data) {
            self.file = decoded
        } else {
            self.file = .empty
        }
    }

    public var fileURL: URL { url }

    public func snapshot() -> CorrectionLogFile {
        queue.sync { file }
    }

    /// Record a user-accepted correction. Skips no-ops (same string ignoring case).
    @discardableResult
    public func record(wrong: String, correct: String, at date: Date = Date()) -> CorrectionRecord? {
        let w = wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = correct.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !c.isEmpty else { return nil }
        guard w.caseInsensitiveCompare(c) != .orderedSame else { return nil }

        return queue.sync {
            reloadFromDiskLocked()
            let id = CorrectionRecord.makeID(wrong: w, correct: c)
            if let idx = file.corrections.firstIndex(where: { $0.id == id }) {
                file.corrections[idx].count += 1
                file.corrections[idx].lastCorrectedAt = date
                // Keep original casing from first sight for wrong; prefer latest correct casing.
                file.corrections[idx].correct = c
                persistLocked()
                return file.corrections[idx]
            } else {
                let record = CorrectionRecord(
                    wrong: w,
                    correct: c,
                    count: 1,
                    firstCorrectedAt: date,
                    lastCorrectedAt: date
                )
                file.corrections.append(record)
                // Keep most frequent first for easy inspection later.
                file.corrections.sort {
                    if $0.count != $1.count { return $0.count > $1.count }
                    return $0.lastCorrectedAt > $1.lastCorrectedAt
                }
                persistLocked()
                return record
            }
        }
    }

    /// Most common wrong→correct pairs (for future suggestion ranking).
    public func topCorrections(limit: Int = 50) -> [CorrectionRecord] {
        queue.sync {
            Array(file.corrections.sorted { $0.count > $1.count }.prefix(limit))
        }
    }

    private func reloadFromDiskLocked() {
        if let data = try? Data(contentsOf: url),
           let decoded = try? decoder.decode(CorrectionLogFile.self, from: data) {
            file = decoded
        }
    }

    private func persistLocked() {
        do {
            let data = try encoder.encode(file)
            try data.write(to: url, options: .atomic)
        } catch {
            // Best-effort; don't crash the editor on disk errors.
        }
    }
}
