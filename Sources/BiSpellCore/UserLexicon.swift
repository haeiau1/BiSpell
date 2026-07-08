import Foundation

public struct UserLexicon: Sendable, Codable, Equatable {
    public var addedWords: Set<String>
    public var ignoredWords: Set<String>
    public var ignoredInApps: [String: Set<String>] // bundleID -> words

    public init(
        addedWords: Set<String> = [],
        ignoredWords: Set<String> = [],
        ignoredInApps: [String: Set<String>] = [:]
    ) {
        self.addedWords = addedWords
        self.ignoredWords = ignoredWords
        self.ignoredInApps = ignoredInApps
    }

    public func accepts(_ word: String) -> Bool {
        let key = word.lowercased()
        return addedWords.contains(word)
            || addedWords.contains(where: { $0.lowercased() == key })
            || ignoredWords.contains(where: { $0.lowercased() == key })
    }

    public func ignores(_ word: String, inApp bundleID: String?) -> Bool {
        if accepts(word) { return true }
        guard let bundleID, let set = ignoredInApps[bundleID] else { return false }
        let key = word.lowercased()
        return set.contains(where: { $0.lowercased() == key })
    }

    public mutating func addWord(_ word: String) {
        addedWords.insert(word)
        ignoredWords.remove(word)
    }

    public mutating func ignoreOnce(_ word: String) {
        ignoredWords.insert(word)
    }

    public mutating func ignoreInApp(_ word: String, bundleID: String) {
        var set = ignoredInApps[bundleID] ?? []
        set.insert(word)
        ignoredInApps[bundleID] = set
    }

    public mutating func removeWord(_ word: String) {
        let key = word.lowercased()
        addedWords = addedWords.filter { $0.lowercased() != key }
    }

    public mutating func unignore(_ word: String) {
        let key = word.lowercased()
        ignoredWords = ignoredWords.filter { $0.lowercased() != key }
        for (bundleID, words) in ignoredInApps {
            let filtered = words.filter { $0.lowercased() != key }
            if filtered.isEmpty {
                ignoredInApps.removeValue(forKey: bundleID)
            } else {
                ignoredInApps[bundleID] = filtered
            }
        }
    }
}

public final class UserLexiconStore: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "BiSpell.UserLexiconStore")
    private var lexicon: UserLexicon

    public init(filename: String = "user-lexicon.json") {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BiSpell", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent(filename)
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(UserLexicon.self, from: data) {
            self.lexicon = decoded
        } else {
            self.lexicon = UserLexicon()
        }
    }

    public func current() -> UserLexicon {
        queue.sync { lexicon }
    }

    public func update(_ body: (inout UserLexicon) -> Void) {
        queue.sync {
            body(&lexicon)
            if let data = try? JSONEncoder().encode(lexicon) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
