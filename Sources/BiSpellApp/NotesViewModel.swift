import Foundation
import SwiftUI
import Combine
import BiSpellCore

@MainActor
final class NotesViewModel: ObservableObject {
    @Published private(set) var notes: [Note] = []
    @Published var selectedNoteID: UUID?
    @Published var searchText: String = ""
    @Published var saveStatus: String = "Ready"
    @Published private(set) var isDirty: Bool = false
    @Published private(set) var misspellings: [Misspelling] = []
    @Published var activeSuggestion: Misspelling?
    @Published var selectedRange: NSRange = NSRange(location: 0, length: 0)
    @Published var draftTitle: String = ""
    @Published var draftBody: String = ""
    @Published var draftLockedSpans: [LockedSpan] = []
    @Published private(set) var draftIsTemplate: Bool = false

    private let store: NotesStore
    private let engine: SpellEngine?
    private let correctionLog: CorrectionLogStore
    private var checkWork: DispatchWorkItem?

    init(
        store: NotesStore = NotesStore(),
        engine: SpellEngine? = nil,
        correctionLog: CorrectionLogStore = CorrectionLogStore()
    ) {
        self.store = store
        self.engine = engine
        self.correctionLog = correctionLog
        reload()
    }

    var regularNotes: [Note] {
        filterList(notes.filter { !$0.isTemplate })
    }

    var templateNotes: [Note] {
        filterList(notes.filter(\.isTemplate))
    }

    var selectedNote: Note? {
        guard let selectedNoteID else { return nil }
        return notes.first { $0.id == selectedNoteID }
    }

    var canLockSelection: Bool {
        selectedRange.length > 0 && selectedNoteID != nil
    }

    var canUnlockSelection: Bool {
        guard selectedNoteID != nil else { return false }
        if selectedRange.length == 0 {
            return draftLockedSpans.contains {
                selectedRange.location >= $0.location && selectedRange.location < $0.location + $0.length
            }
        }
        return draftLockedSpans.contains { NSIntersectionRange($0.utf16Range, selectedRange).length > 0 }
    }

    var titleBinding: Binding<String> {
        Binding(get: { self.draftTitle }, set: { self.setTitle($0) })
    }

    var bodyBinding: Binding<String> {
        Binding(get: { self.draftBody }, set: { self.setBody($0) })
    }

    func reload() {
        do {
            notes = try store.loadAll()
            if notes.isEmpty {
                createNote(saveImmediately: true)
                return
            }
            if selectedNoteID == nil || !notes.contains(where: { $0.id == selectedNoteID }) {
                selectedNoteID = regularNotes.first?.id ?? notes.first?.id
            }
            syncDraftFromSelection()
            scheduleSpellCheck(autoPopup: false)
            saveStatus = "Ready"
            isDirty = false
        } catch {
            saveStatus = "Load failed"
        }
    }

    func createNote(saveImmediately: Bool = true, asTemplate: Bool = false) {
        var note = Note(title: asTemplate ? "Untitled template" : "Untitled", body: "", isTemplate: asTemplate)
        note.updatedAt = Date()
        do {
            if saveImmediately { try store.save(note) }
            notes.insert(note, at: 0)
            selectedNoteID = note.id
            syncDraftFromSelection()
            isDirty = !saveImmediately
            saveStatus = saveImmediately ? "Created" : "Unsaved"
            misspellings = []
            activeSuggestion = nil
        } catch {
            saveStatus = "Create failed"
        }
    }

    /// New regular note cloned from a template (body + locked spans).
    func createNoteFromTemplate(_ templateID: UUID) {
        guard let template = notes.first(where: { $0.id == templateID && $0.isTemplate }) else { return }
        flushPendingSave()
        var note = Note(
            title: template.title == "Untitled template" ? "Untitled" : template.title,
            body: template.body,
            isTemplate: false,
            lockedSpans: template.lockedSpans
        )
        note.updatedAt = Date()
        do {
            try store.save(note)
            notes.insert(note, at: 0)
            selectedNoteID = note.id
            syncDraftFromSelection()
            isDirty = false
            saveStatus = "From template"
            scheduleSpellCheck(autoPopup: false)
        } catch {
            saveStatus = "Create failed"
        }
    }

    /// Move current note into Templates section (or create template copy).
    func saveCurrentAsTemplate() {
        guard selectedNoteID != nil else { return }
        draftIsTemplate = true
        markDirty()
        persistDraftNow()
        saveStatus = "Saved as template"
    }

    /// Move template back to regular notes.
    func convertTemplateToNote() {
        guard draftIsTemplate else { return }
        draftIsTemplate = false
        markDirty()
        persistDraftNow()
        saveStatus = "Moved to notes"
    }

    func deleteSelected() {
        guard let id = selectedNoteID else { return }
        delete(id: id)
    }

    func delete(id: UUID) {
        checkWork?.cancel()
        do {
            try store.delete(id: id)
            notes.removeAll { $0.id == id }
            if selectedNoteID == id {
                selectedNoteID = regularNotes.first?.id ?? templateNotes.first?.id
                syncDraftFromSelection()
                scheduleSpellCheck(autoPopup: false)
            }
            isDirty = false
            saveStatus = "Deleted"
            activeSuggestion = nil
        } catch {
            saveStatus = "Delete failed"
        }
    }

    @discardableResult
    func select(id: UUID?, force: Bool = false) -> Bool {
        if !force, isDirty, id != selectedNoteID { return false }
        selectedNoteID = id
        syncDraftFromSelection()
        isDirty = false
        saveStatus = "Ready"
        scheduleSpellCheck(autoPopup: false)
        return true
    }

    func setTitle(_ value: String) {
        guard draftTitle != value else { return }
        draftTitle = value
        markDirty()
    }

    func setBody(_ value: String) {
        // Direct set from binding without range math — editor uses applyEdit for gated changes.
        guard draftBody != value else { return }
        draftBody = value
        draftLockedSpans = LockedSpanMath.clamp(draftLockedSpans, toTextLength: (value as NSString).length)
        markDirty()
        scheduleSpellCheck(autoPopup: false)
    }

    /// Called by editor before applying an edit. Returns false if locked text would change.
    func canEdit(range: NSRange, replacement: String) -> Bool {
        !LockedSpanMath.anyBlocks(draftLockedSpans, edit: range)
    }

    /// Apply text replacement that was allowed by the editor; updates locks.
    func applyEdit(range: NSRange, replacement: String) {
        let ns = draftBody as NSString
        guard range.location + range.length <= ns.length else { return }
        guard canEdit(range: range, replacement: replacement) else { return }
        draftBody = ns.replacingCharacters(in: range, with: replacement)
        draftLockedSpans = LockedSpanMath.adjusting(
            draftLockedSpans,
            edited: range,
            replacementLength: (replacement as NSString).length
        )
        draftLockedSpans = LockedSpanMath.clamp(draftLockedSpans, toTextLength: (draftBody as NSString).length)
        let caret = range.location + (replacement as NSString).length
        selectedRange = NSRange(location: caret, length: 0)
        markDirty()
        scheduleSpellCheck(autoPopup: false)
    }

    func markDirtyFromEditor() {
        markDirty()
        scheduleSpellCheck(autoPopup: false)
    }

    func handleWordBoundary() {
        scheduleSpellCheck(autoPopup: true, delay: 0.05)
    }

    func lockSelection() {
        guard selectedRange.length > 0 else {
            saveStatus = "Select text to lock"
            return
        }
        draftLockedSpans = LockedSpanMath.add(draftLockedSpans, range: selectedRange)
        markDirty()
        saveStatus = "Locked selection"
    }

    func unlockSelection() {
        draftLockedSpans = LockedSpanMath.remove(draftLockedSpans, intersecting: selectedRange)
        markDirty()
        saveStatus = "Unlocked"
    }

    func save() { persistDraftNow() }

    func flushPendingSave() {
        if isDirty { persistDraftNow() }
    }

    func applySuggestion(_ suggestion: String, for misspelling: Misspelling) {
        let range = misspelling.utf16Range
        guard canEdit(range: range, replacement: suggestion) else {
            saveStatus = "Can't edit locked text"
            return
        }
        let wrong = misspelling.word
        applyEdit(range: range, replacement: suggestion)
        activeSuggestion = nil
        _ = correctionLog.record(wrong: wrong, correct: suggestion)
        saveStatus = "Fixed “\(wrong)” → \(suggestion)"
    }

    func dismissSuggestions() {
        activeSuggestion = nil
    }

    func applySuggestionShortcut(number: Int) {
        let idx = number - 1
        guard idx >= 0 else { return }

        if let active = activeSuggestion {
            let filled = fillSuggestions(active)
            guard filled.suggestions.indices.contains(idx) else { return }
            applySuggestion(filled.suggestions[idx], for: filled)
            return
        }

        runSpellCheck(autoPopup: false)
        guard let nearest = nearestMisspelling(to: selectedRange.location) else { return }
        let filled = fillSuggestions(nearest)
        guard filled.suggestions.indices.contains(idx) else {
            activeSuggestion = filled
            return
        }
        applySuggestion(filled.suggestions[idx], for: filled)
    }

    func handleSuggestionHotkey() {
        runSpellCheck(autoPopup: true)
        if activeSuggestion == nil {
            saveStatus = "No spelling issues near caret"
        }
    }

    // MARK: - Private

    private func filterList(_ list: [Note]) -> [Note] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = list.sorted { $0.updatedAt > $1.updatedAt }
        guard !q.isEmpty else { return base }
        return base.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(q)
                || $0.body.localizedCaseInsensitiveContains(q)
        }
    }

    private func markDirty() {
        isDirty = true
        if saveStatus != "Save failed" {
            saveStatus = "Unsaved"
        }
    }

    private func syncDraftFromSelection() {
        if let note = selectedNote {
            draftTitle = note.title
            draftBody = note.body
            draftLockedSpans = note.lockedSpans
            draftIsTemplate = note.isTemplate
            selectedRange = NSRange(location: (note.body as NSString).length, length: 0)
        } else {
            draftTitle = ""
            draftBody = ""
            draftLockedSpans = []
            draftIsTemplate = false
            selectedRange = NSRange(location: 0, length: 0)
        }
        misspellings = []
        activeSuggestion = nil
    }

    private func persistDraftNow() {
        guard let id = selectedNoteID,
              let index = notes.firstIndex(where: { $0.id == id }) else { return }
        var note = notes[index]
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        note.title = title.isEmpty ? (draftIsTemplate ? "Untitled template" : "Untitled") : title
        note.body = draftBody
        note.isTemplate = draftIsTemplate
        note.lockedSpans = LockedSpanMath.clamp(draftLockedSpans, toTextLength: (draftBody as NSString).length)
        note.updatedAt = Date()
        do {
            try store.save(note)
            notes[index] = note
            notes.sort { $0.updatedAt > $1.updatedAt }
            isDirty = false
            saveStatus = "Saved"
        } catch {
            saveStatus = "Save failed"
        }
    }

    private func scheduleSpellCheck(autoPopup: Bool, delay: TimeInterval = 0.25) {
        checkWork?.cancel()
        guard engine != nil else {
            misspellings = []
            activeSuggestion = nil
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.runSpellCheck(autoPopup: autoPopup)
        }
        checkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func runSpellCheck(autoPopup: Bool) {
        guard let engine else { return }
        let text = draftBody
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            misspellings = []
            activeSuggestion = nil
            return
        }
        let result = engine.check(text: text, nearCaretOnly: false)
        // Ignore issues inside locked spans (templates shouldn't nag).
        misspellings = result.misspellings.filter { miss in
            !LockedSpanMath.anyBlocks(draftLockedSpans, edit: miss.utf16Range)
        }

        guard autoPopup else {
            if let active = activeSuggestion {
                if let still = misspellings.first(where: {
                    $0.utf16Range == active.utf16Range || $0.word == active.word
                }) {
                    activeSuggestion = fillSuggestions(still)
                } else {
                    activeSuggestion = nil
                }
            }
            return
        }

        if let justFinished = misspellingJustFinished(caret: selectedRange.location) {
            let filled = fillSuggestions(justFinished)
            activeSuggestion = filled.suggestions.isEmpty ? nil : filled
            if let filled = activeSuggestion {
                selectedRange = filled.utf16Range
                saveStatus = "⌘1–⌘5 to fix “\(filled.word)”"
            }
            return
        }

        if let nearest = nearestMisspelling(to: selectedRange.location) {
            let filled = fillSuggestions(nearest)
            activeSuggestion = filled.suggestions.isEmpty ? nil : filled
            if activeSuggestion != nil {
                saveStatus = "⌘1–⌘5 to fix “\(filled.word)”"
            }
        } else {
            activeSuggestion = nil
        }
    }

    private func misspellingJustFinished(caret: Int) -> Misspelling? {
        let ns = draftBody as NSString
        var end = min(caret, ns.length)
        while end > 0 {
            let ch = ns.substring(with: NSRange(location: end - 1, length: 1))
            if isBoundaryChar(ch) { end -= 1 } else { break }
        }
        guard end > 0 else { return nil }
        return misspellings.first { $0.utf16Range.location + $0.utf16Range.length == end }
    }

    private func isBoundaryChar(_ s: String) -> Bool {
        guard let u = s.unicodeScalars.first else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(u)
            || CharacterSet.punctuationCharacters.contains(u)
    }

    private func fillSuggestions(_ misspelling: Misspelling) -> Misspelling {
        guard let engine else { return misspelling }
        if !misspelling.suggestions.isEmpty { return misspelling }
        return engine.withSuggestions(misspelling)
    }

    private func nearestMisspelling(to caret: Int) -> Misspelling? {
        guard !misspellings.isEmpty else { return nil }
        if let inside = misspellings.first(where: {
            caret >= $0.utf16Range.location && caret <= $0.utf16Range.location + $0.utf16Range.length
        }) {
            return inside
        }
        if let before = misspellings
            .filter({ caret >= $0.utf16Range.location + $0.utf16Range.length })
            .min(by: {
                (caret - ($0.utf16Range.location + $0.utf16Range.length))
                    < (caret - ($1.utf16Range.location + $1.utf16Range.length))
            }),
           caret - (before.utf16Range.location + before.utf16Range.length) <= 3 {
            return before
        }
        return misspellings.min(by: {
            let mid0 = $0.utf16Range.location + $0.utf16Range.length / 2
            let mid1 = $1.utf16Range.location + $1.utf16Range.length / 2
            return abs(mid0 - caret) < abs(mid1 - caret)
        })
    }
}
