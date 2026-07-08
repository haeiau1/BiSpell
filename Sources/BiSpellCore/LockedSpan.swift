import Foundation

/// UTF-16 span that cannot be edited (copy/select still allowed).
public struct LockedSpan: Codable, Equatable, Sendable, Hashable {
    public var location: Int
    public var length: Int

    public init(location: Int, length: Int) {
        self.location = max(0, location)
        self.length = max(0, length)
    }

    public init(range: NSRange) {
        self.location = max(0, range.location)
        self.length = max(0, range.length)
    }

    public var utf16Range: NSRange {
        NSRange(location: location, length: length)
    }

    public var isEmpty: Bool { length == 0 }

    /// True if an attempted edit of `edit` would modify locked characters.
    public func blocksEdit(in edit: NSRange) -> Bool {
        if edit.length == 0 {
            // Caret insertion: allow at span edges, block strictly inside.
            return edit.location > location && edit.location < location + length
        }
        return NSIntersectionRange(utf16Range, edit).length > 0
    }
}

public enum LockedSpanMath {
    public static func normalize(_ spans: [LockedSpan]) -> [LockedSpan] {
        let sorted = spans.filter { $0.length > 0 }.sorted { $0.location < $1.location }
        guard var current = sorted.first else { return [] }
        var out: [LockedSpan] = []
        for span in sorted.dropFirst() {
            let currentEnd = current.location + current.length
            if span.location <= currentEnd {
                let end = max(currentEnd, span.location + span.length)
                current = LockedSpan(location: current.location, length: end - current.location)
            } else {
                out.append(current)
                current = span
            }
        }
        out.append(current)
        return out
    }

    public static func add(_ spans: [LockedSpan], range: NSRange) -> [LockedSpan] {
        guard range.length > 0 else { return normalize(spans) }
        return normalize(spans + [LockedSpan(range: range)])
    }

    /// Remove locks overlapping selection; for caret, unlock the span containing the caret.
    public static func remove(_ spans: [LockedSpan], intersecting range: NSRange) -> [LockedSpan] {
        if range.length == 0 {
            return spans.filter { span in
                !(range.location >= span.location && range.location < span.location + span.length)
            }
        }
        return spans.filter { NSIntersectionRange($0.utf16Range, range).length == 0 }
    }

    public static func anyBlocks(_ spans: [LockedSpan], edit: NSRange) -> Bool {
        spans.contains { $0.blocksEdit(in: edit) }
    }

    /// True if every UTF-16 unit of `range` is covered by some locked span.
    public static func fullyLocked(_ range: NSRange, spans: [LockedSpan]) -> Bool {
        guard range.length > 0 else {
            return anyBlocks(spans, edit: range)
        }
        let unlocked = unlockedSegments(of: range, spans: spans)
        return unlocked.isEmpty
    }

    /// True if `range` overlaps any lock and also has unlocked content.
    public static func isMixedSelection(_ range: NSRange, spans: [LockedSpan]) -> Bool {
        guard range.length > 0 else { return false }
        let overlapsLock = spans.contains { NSIntersectionRange($0.utf16Range, range).length > 0 }
        let unlocked = unlockedSegments(of: range, spans: spans)
        return overlapsLock && !unlocked.isEmpty
    }

    /// Sub-ranges of `range` not covered by any locked span (normalized).
    public static func unlockedSegments(of range: NSRange, spans: [LockedSpan]) -> [NSRange] {
        guard range.length > 0 else { return [] }
        let rangeEnd = range.location + range.length
        let norm = normalize(spans)
        // Collect overlaps with range, clipped.
        var lockedInRange: [NSRange] = []
        for span in norm {
            let inter = NSIntersectionRange(span.utf16Range, range)
            if inter.length > 0 {
                lockedInRange.append(inter)
            }
        }
        lockedInRange.sort { $0.location < $1.location }

        var result: [NSRange] = []
        var cursor = range.location
        for lock in lockedInRange {
            if lock.location > cursor {
                result.append(NSRange(location: cursor, length: lock.location - cursor))
            }
            cursor = max(cursor, lock.location + lock.length)
        }
        if cursor < rangeEnd {
            result.append(NSRange(location: cursor, length: rangeEnd - cursor))
        }
        return result.filter { $0.length > 0 }
    }

    /// After a permitted edit (must not overlap locks), shift spans after the edit point.
    public static func adjusting(
        _ spans: [LockedSpan],
        edited: NSRange,
        replacementLength: Int
    ) -> [LockedSpan] {
        let delta = replacementLength - edited.length
        let editEnd = edited.location + edited.length
        var result: [LockedSpan] = []
        for span in spans {
            let spanEnd = span.location + span.length
            if edited.location >= spanEnd {
                result.append(span)
            } else if editEnd <= span.location {
                result.append(LockedSpan(location: span.location + delta, length: span.length))
            }
            // Overlap: drop (should not occur if edits are gated).
        }
        return normalize(result)
    }

    /// Apply several pure deletions back-to-front and return new spans (for tests / batch).
    public static func applyingDeletions(_ spans: [LockedSpan], segments: [NSRange]) -> [LockedSpan] {
        var current = spans
        for seg in segments.sorted(by: { $0.location > $1.location }) {
            current = adjusting(current, edited: seg, replacementLength: 0)
        }
        return current
    }

    public static func clamp(_ spans: [LockedSpan], toTextLength len: Int) -> [LockedSpan] {
        normalize(spans.compactMap { span in
            guard span.location < len else { return nil }
            let length = min(span.length, len - span.location)
            guard length > 0 else { return nil }
            return LockedSpan(location: span.location, length: length)
        })
    }
}
