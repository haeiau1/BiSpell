import Foundation
import SwiftUI
import AppKit
import Combine
import BiSpellCore

struct TemplateVariableFormState: Identifiable, Equatable {
    let id = UUID()
    let templateID: UUID
    let keys: [String]
    var values: [String: String]
}


enum NoteSortMode: String, CaseIterable, Identifiable {
    case updated
    case title
    case path

    var id: String { rawValue }

    var label: String {
        switch self {
        case .updated: return "Updated"
        case .title: return "Title"
        case .path: return "Path"
        }
    }
}

enum NoteEditorMode: String, CaseIterable, Identifiable {
    case source
    case split
    case preview

    var id: String { rawValue }

    var label: String {
        switch self {
        case .source: return "Source"
        case .split: return "Split"
        case .preview: return "Preview"
        }
    }

    var systemImage: String {
        switch self {
        case .source: return "chevron.left.forwardslash.chevron.right"
        case .split: return "rectangle.split.2x1"
        case .preview: return "doc.richtext"
        }
    }
}

/// Which note pane is focused when note-split (side-by-side notes) is on.
enum NoteSplitPane: String, Equatable {
    case primary
    case secondary
}

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
    @Published var draftFolder: String = ""
    @Published var draftTagsText: String = ""
    @Published var selectedTagFilters: Set<String> = []
    @Published var selectedFolderFilter: String? = nil
    /// Pending variable form when instantiating a template.
    @Published var pendingVariableForm: TemplateVariableFormState?
    /// Source | Split | Preview for markdown end-product view.
    @Published var editorMode: NoteEditorMode = .source
    @Published var sortMode: NoteSortMode = .updated
    /// Quick switcher (⌘P) query / visibility driven from UI.
    @Published var quickSwitcherQuery: String = ""
    @Published var showQuickSwitcher: Bool = false
    @Published var libraryDisplayPath: String = ""

    // MARK: Tabs + note split (side-by-side notes — not Source/Preview split)

    /// Open notes as tabs (ordered). Always contains `selectedNoteID` when set.
    @Published private(set) var openTabIDs: [UUID] = []
    /// When true, show a second note pane to the right of the primary editor.
    @Published var isNoteSplit: Bool = false
    /// Note shown in the secondary (right) pane when `isNoteSplit`.
    @Published var secondaryNoteID: UUID?
    @Published var focusedPane: NoteSplitPane = .primary

    /// Secondary pane draft (independent of primary `draft*` fields).
    @Published var secondaryDraftTitle: String = ""
    @Published var secondaryDraftBody: String = ""
    @Published var secondaryDraftLockedSpans: [LockedSpan] = []
    @Published private(set) var secondaryDraftIsTemplate: Bool = false
    @Published var secondaryDraftFolder: String = ""
    @Published var secondaryDraftTagsText: String = ""
    @Published private(set) var secondaryIsDirty: Bool = false
    @Published var secondarySelectedRange: NSRange = NSRange(location: 0, length: 0)
    @Published var secondaryEditorMode: NoteEditorMode = .source
    @Published private(set) var secondaryMisspellings: [Misspelling] = []
    @Published var secondaryActiveSuggestion: Misspelling?

    private var store: NotesStore
    private let engine: SpellEngine?
    private let correctionLog: CorrectionLogStore
    let editorBridge = NoteEditorBridge()
    let secondaryEditorBridge = NoteEditorBridge()
    private var checkWork: DispatchWorkItem?
    private var diskWatchTimer: Timer?
    private var knownMTimes: [UUID: Date] = [:]
    private var isApplyingDiskReload = false
    /// Per-note-session dismissed misspelling occurrences (range + word). Cleared on note switch.
    /// A newly typed instance of the same word is a different occurrence and may re-flag.
    private var dismissedOccurrences: [DismissedMisspelling] = []

    /// Full-document spell-check is expensive on large markdown imports.
    private static let fullSpellCheckUTF16Limit = 24_000

    /// One dismissed spelling instance on the open note (UTF-16 range + word identity).
    private struct DismissedMisspelling: Equatable {
        var location: Int
        var length: Int
        var word: String

        var utf16Range: NSRange { NSRange(location: location, length: length) }

        init(location: Int, length: Int, word: String) {
            self.location = location
            self.length = length
            self.word = word
        }

        init(_ misspelling: Misspelling) {
            self.location = misspelling.utf16Range.location
            self.length = misspelling.utf16Range.length
            self.word = misspelling.word
        }

        func matches(_ misspelling: Misspelling) -> Bool {
            location == misspelling.utf16Range.location
                && length == misspelling.utf16Range.length
                && word == misspelling.word
        }
    }

    init(
        store: NotesStore = NotesStore(),
        engine: SpellEngine? = nil,
        correctionLog: CorrectionLogStore = CorrectionLogStore(),
        autoMigrateLegacy: Bool = true
    ) {
        self.store = store
        self.engine = engine
        self.correctionLog = correctionLog
        self.libraryDisplayPath = LibraryPaths.displayPath(for: store.libraryRoot)
        if autoMigrateLegacy {
            try? autoMigrateIfNeeded()
        }
        reload()
        startDiskWatch()
    }

    /// Rebind library root (Settings). Flushes dirty draft first if possible.
    func rebindLibrary(to url: URL, migrateLegacy: Bool = false) {
        guard flushPendingSave() else { return }
        do {
            try store.setLibraryRoot(url)
            libraryDisplayPath = LibraryPaths.displayPath(for: url)
            if migrateLegacy {
                _ = try store.migrateFromAppSupport()
            } else {
                try? autoMigrateIfNeeded()
            }
            selectedNoteID = nil
            secondaryNoteID = nil
            isNoteSplit = false
            focusedPane = .primary
            openTabIDs = []
            clearSecondaryDraft()
            secondaryIsDirty = false
            reload()
            saveStatus = "Library: \(libraryDisplayPath)"
        } catch {
            saveStatus = "Library change failed"
        }
    }

    @discardableResult
    private func autoMigrateIfNeeded() throws -> Int {
        let existing = (try? store.loadAll()) ?? []
        guard existing.isEmpty, store.hasLegacyAppSupportNotes else { return 0 }
        let n = try store.migrateFromAppSupport()
        if n > 0 {
            saveStatus = "Migrated \(n) note(s) from App Support"
        }
        return n
    }

    /// Import legacy App Support JSON notes. Flushes dirty draft first so reload
    /// cannot discard unsaved work; skips reload when nothing was imported.
    @discardableResult
    func migrateFromAppSupport() -> Int {
        guard flushPendingSave() else { return 0 }
        do {
            let n = try store.migrateFromAppSupport()
            if n > 0 {
                reload()
                saveStatus = "Migrated \(n) note(s)"
            } else {
                saveStatus = "Nothing to migrate"
            }
            return n
        } catch {
            saveStatus = "Migration failed"
            return 0
        }
    }

    var libraryRootURL: URL { store.libraryRoot }

    var regularNotes: [Note] {
        filterList(notes.filter { !$0.isTemplate })
    }

    var templateNotes: [Note] {
        filterList(notes.filter(\.isTemplate))
    }

    var allTags: [String] {
        var set = Set<String>()
        for n in notes {
            for tag in n.tags { set.insert(tag) }
        }
        // also draft tags
        for tag in NoteTagging.parseTagString(draftTagsText) { set.insert(tag) }
        return set.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var allFolders: [String] {
        var set = Set(store.knownFoldersOnDisk())
        for n in notes {
            if let f = n.folder { set.insert(f) }
        }
        if let f = NoteTagging.normalizeFolder(draftFolder) { set.insert(f) }
        return set.sorted()
    }

    /// Relative path for status bar / reveal.
    func relativePath(for id: UUID?) -> String? {
        guard let id else { return nil }
        return store.relativePath(for: id)
    }

    var selectedRelativePath: String? {
        relativePath(for: selectedNoteID)
    }

    var selectedNote: Note? {
        guard let selectedNoteID else { return nil }
        return notes.first { $0.id == selectedNoteID }
    }

    var secondaryNote: Note? {
        guard let secondaryNoteID else { return nil }
        return notes.first { $0.id == secondaryNoteID }
    }

    /// Bridge for the focused pane (spelling undo targets the active editor).
    var activeEditorBridge: NoteEditorBridge {
        focusedPane == .secondary && isNoteSplit ? secondaryEditorBridge : editorBridge
    }

    /// True if primary or (when split) secondary draft has unsaved changes.
    var hasAnyUnsavedChanges: Bool {
        isDirty || (isNoteSplit && secondaryIsDirty)
    }

    /// Both panes show the same note id (two views of one file).
    var isSameNoteInBothPanes: Bool {
        isNoteSplit
            && selectedNoteID != nil
            && selectedNoteID == secondaryNoteID
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
                openTabIDs = []
                secondaryNoteID = nil
                isNoteSplit = false
                createNote(saveImmediately: true)
                return
            }
            openTabIDs = openTabIDs.filter { id in notes.contains(where: { $0.id == id }) }
            if selectedNoteID == nil || !notes.contains(where: { $0.id == selectedNoteID }) {
                selectedNoteID = openTabIDs.first ?? regularNotes.first?.id ?? notes.first?.id
            }
            if let sid = selectedNoteID { ensureOpenTab(sid) }
            if let sec = secondaryNoteID, !notes.contains(where: { $0.id == sec }) {
                secondaryNoteID = nil
                isNoteSplit = false
            }
            syncDraftFromSelection()
            if isNoteSplit {
                syncSecondaryDraftFromID()
            }
            scheduleSpellCheck(autoPopup: false)
            saveStatus = "Ready"
            isDirty = false
            secondaryIsDirty = false
        } catch {
            saveStatus = "Load failed"
        }
    }

    func createNote(saveImmediately: Bool = true, asTemplate: Bool = false) {
        let folder = asTemplate ? LibraryPaths.templates : LibraryPaths.inbox
        var note = Note(
            title: asTemplate ? "Untitled template" : "Untitled",
            body: "",
            isTemplate: asTemplate,
            folder: folder
        )
        note.updatedAt = Date()
        do {
            if saveImmediately { try store.save(note) }
            notes.insert(note, at: 0)
            if saveImmediately, let all = try? store.loadAll(), let saved = all.first(where: { $0.id == note.id }) {
                if let idx = notes.firstIndex(where: { $0.id == note.id }) {
                    notes[idx] = saved
                }
                note = saved
            }
            selectedNoteID = note.id
            focusedPane = .primary
            ensureOpenTab(note.id)
            syncDraftFromSelection()
            isDirty = !saveImmediately
            saveStatus = saveImmediately ? "Created in \(note.folder ?? LibraryPaths.inbox)" : "Unsaved"
            misspellings = []
            activeSuggestion = nil
            refreshMTimes()
        } catch {
            saveStatus = "Create failed"
        }
    }

    /// Open or create today's daily note (`daily/YYYY-MM-DD.md`).
    func openToday(date: Date = Date()) {
        guard flushPendingSave() else { return }
        let day = LibraryPaths.dailyFileName(for: date)
        if let existing = notes.first(where: {
            $0.folder == LibraryPaths.daily && (
                store.fileRef(for: $0.id)?.basename == day || $0.title == day
            )
        }) {
            _ = select(id: existing.id, force: true)
            saveStatus = "Today · \(day)"
            return
        }
        if let all = try? store.loadAll(),
           let existing = all.first(where: {
               $0.folder == LibraryPaths.daily && (store.fileRef(for: $0.id)?.basename == day || $0.title == day)
           }) {
            notes = all
            _ = select(id: existing.id, force: true)
            saveStatus = "Today · \(day)"
            return
        }
        var note = Note(
            title: day,
            body: "# \(day)\n\n",
            isTemplate: false,
            folder: LibraryPaths.daily,
            tags: ["daily"]
        )
        note.updatedAt = Date()
        do {
            try store.save(note)
            if let all = try? store.loadAll() {
                notes = all
                if let saved = all.first(where: { $0.id == note.id }) {
                    selectedNoteID = saved.id
                } else {
                    selectedNoteID = note.id
                }
            } else {
                notes.insert(note, at: 0)
                selectedNoteID = note.id
            }
            focusedPane = .primary
            if let id = selectedNoteID { ensureOpenTab(id) }
            syncDraftFromSelection()
            isDirty = false
            saveStatus = "Today · \(day)"
            scheduleSpellCheck(autoPopup: false)
            refreshMTimes()
        } catch {
            saveStatus = "Could not open today"
        }
    }

    /// Apply template: appends filled body + locks onto the current note when one is open;
    /// otherwise creates a new note. May open variable form. Returns false if dirty (unless force)
    /// or if a forced flush fails (draft is kept; status stays "Save failed").
    @discardableResult
    func createNoteFromTemplate(_ templateID: UUID, force: Bool = false) -> Bool {
        if isDirty, !force { return false }
        guard let template = notes.first(where: { $0.id == templateID && $0.isTemplate }) else { return false }
        // Never open the form / create if a dirty draft could not be flushed.
        guard flushPendingSave() else { return false }

        let keys = TemplateVariables.orderedKeysUnlocked(in: template.body, locks: template.lockedSpans)
        if keys.isEmpty {
            return finalizeNoteFromTemplate(template, values: [:])
        }
        var vals: [String: String] = [:]
        for k in keys { vals[k] = "" }
        pendingVariableForm = TemplateVariableFormState(templateID: templateID, keys: keys, values: vals)
        return true
    }

    func cancelVariableForm() {
        pendingVariableForm = nil
    }

    func submitVariableForm(values: [String: String]) {
        guard let form = pendingVariableForm,
              let template = notes.first(where: { $0.id == form.templateID && $0.isTemplate }) else {
            pendingVariableForm = nil
            return
        }
        pendingVariableForm = nil
        _ = finalizeNoteFromTemplate(template, values: values)
    }

    /// True when we should append template content into the open draft (not replace / not new note).
    private var shouldAppendTemplateToCurrentNote: Bool {
        guard let id = selectedNoteID else { return false }
        // Don't mutate a template document itself — open a new note instead.
        if draftIsTemplate { return false }
        // Don't append into the template source when it is the selection.
        if notes.first(where: { $0.id == id })?.isTemplate == true { return false }
        return true
    }

    @discardableResult
    private func finalizeNoteFromTemplate(_ template: Note, values: [String: String]) -> Bool {
        let filled = TemplateVariables.fill(
            body: template.body,
            locks: template.lockedSpans,
            values: values
        )
        if shouldAppendTemplateToCurrentNote {
            return appendTemplateToCurrentNote(filled: filled)
        }
        return createNewNoteFromFilledTemplate(template, filled: filled)
    }

    /// Append filled template body and offset locks to the end of the current draft.
    /// Existing body text and existing locks are preserved.
    @discardableResult
    private func appendTemplateToCurrentNote(filled: TemplateFillResult) -> Bool {
        let existing = draftBody
        let existingLen = (existing as NSString).length
        var separator = ""
        if existingLen > 0 {
            if existing.hasSuffix("\n\n") {
                separator = ""
            } else if existing.hasSuffix("\n") {
                separator = "\n"
            } else {
                separator = "\n\n"
            }
        }
        let offset = existingLen + (separator as NSString).length
        let newBody = existing + separator + filled.body
        let offsetLocks = filled.lockedSpans.map { span in
            LockedSpan(
                location: span.location + offset,
                length: span.length,
                label: span.label
            )
        }
        // Preserve existing locks; merge appended template locks (normalized).
        draftBody = newBody
        draftLockedSpans = LockedSpanMath.normalize(draftLockedSpans + offsetLocks)
        draftLockedSpans = LockedSpanMath.clamp(
            draftLockedSpans,
            toTextLength: (newBody as NSString).length
        )
        selectedRange = NSRange(location: (newBody as NSString).length, length: 0)
        markDirty()
        mirrorPrimaryDraftToSecondaryIfShared(fields: .body)
        var status = "Template appended"
        if filled.filledCount > 0 {
            status += " · filled \(filled.filledCount)"
        }
        if filled.skippedInLocks > 0 {
            status += " · \(filled.skippedInLocks) in locks skipped"
        }
        saveStatus = status
        scheduleSpellCheck(autoPopup: false)
        return true
    }

    @discardableResult
    private func createNewNoteFromFilledTemplate(_ template: Note, filled: TemplateFillResult) -> Bool {
        let title: String = {
            let t = template.title
            if t == "Untitled template" || t.isEmpty { return "Untitled" }
            return t
        }()
        var note = Note(
            title: title,
            body: filled.body,
            isTemplate: false,
            lockedSpans: filled.lockedSpans,
            folder: template.folder == LibraryPaths.templates ? LibraryPaths.inbox : (template.folder ?? LibraryPaths.inbox),
            tags: template.tags
        )
        note.updatedAt = Date()
        do {
            try store.save(note)
            notes.insert(note, at: 0)
            selectedNoteID = note.id
            focusedPane = .primary
            ensureOpenTab(note.id)
            syncDraftFromSelection()
            isDirty = false
            var status = "From template"
            if filled.filledCount > 0 {
                status += " · filled \(filled.filledCount)"
            }
            if filled.skippedInLocks > 0 {
                status += " · \(filled.skippedInLocks) in locks skipped"
            }
            saveStatus = status
            scheduleSpellCheck(autoPopup: false)
            return true
        } catch {
            saveStatus = "Create failed"
            return false
        }
    }

    /// Move current note into Templates section (or create template copy).
    func saveCurrentAsTemplate() {
        guard selectedNoteID != nil else { return }
        draftIsTemplate = true
        draftFolder = LibraryPaths.templates
        markDirty()
        // Only claim success when the draft actually landed on disk.
        guard flushPendingSave() else { return }
        saveStatus = "Saved as template"
    }

    /// Move template back to regular notes.
    func convertTemplateToNote() {
        guard draftIsTemplate else { return }
        draftIsTemplate = false
        if draftFolder == LibraryPaths.templates {
            draftFolder = LibraryPaths.inbox
        }
        markDirty()
        guard flushPendingSave() else { return }
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
            openTabIDs.removeAll { $0 == id }
            if secondaryNoteID == id {
                secondaryNoteID = nil
                secondaryIsDirty = false
                isNoteSplit = false
                focusedPane = .primary
                clearSecondaryDraft()
            }
            if selectedNoteID == id {
                // Discarding the selected note — re-sync draft and clear dirty.
                selectedNoteID = openTabIDs.first ?? regularNotes.first?.id ?? templateNotes.first?.id
                if let sid = selectedNoteID { ensureOpenTab(sid) }
                syncDraftFromSelection()
                isDirty = false
                scheduleSpellCheck(autoPopup: false)
                activeSuggestion = nil
            }
            // Trashing a non-selected note must not clear isDirty / wipe an unsaved draft on the open note.
            saveStatus = "Moved to trash"
        } catch {
            saveStatus = "Delete failed"
        }
    }

    @discardableResult
    func select(id: UUID?, force: Bool = false) -> Bool {
        // When note-split is focused on the right pane, sidebar/tab selection targets that pane.
        if isNoteSplit, focusedPane == .secondary {
            return selectSecondary(id: id, force: force)
        }
        if !force, isDirty, id != selectedNoteID { return false }
        selectedNoteID = id
        if let id { ensureOpenTab(id) }
        syncDraftFromSelection()
        isDirty = false
        saveStatus = "Ready"
        scheduleSpellCheck(autoPopup: false)
        return true
    }

    /// Open / focus a note in the secondary (right) pane.
    @discardableResult
    func selectSecondary(id: UUID?, force: Bool = false) -> Bool {
        if id == secondaryNoteID {
            focusPane(.secondary)
            return true
        }
        // Leaving a dirty right pane (or shared dual-view of another note).
        if isSameNoteInBothPanes {
            guard force || flushAllPendingSaves() else { return false }
        } else if !force, secondaryIsDirty {
            return false
        }
        secondaryNoteID = id
        if let id {
            ensureOpenTab(id)
            isNoteSplit = true
        }
        if let id, id == selectedNoteID {
            // Same file as left pane: share the live primary draft (including unsaved edits).
            copyPrimaryDraftToSecondary(includingSelection: false)
            secondaryIsDirty = isDirty
        } else {
            syncSecondaryDraftFromID()
            secondaryIsDirty = false
        }
        secondaryActiveSuggestion = nil
        saveStatus = "Ready"
        return true
    }

    func ensureOpenTab(_ id: UUID) {
        if !openTabIDs.contains(id) {
            openTabIDs.append(id)
        }
    }

    /// Activate a tab in the focused pane.
    @discardableResult
    func activateTab(_ id: UUID, force: Bool = false) -> Bool {
        select(id: id, force: force)
    }

    /// Close a tab. Flushes that note's draft if it is open in a pane.
    @discardableResult
    func closeTab(_ id: UUID) -> Bool {
        if selectedNoteID == id, isDirty {
            guard flushPrimarySave() else { return false }
        }
        if secondaryNoteID == id, secondaryIsDirty {
            guard flushSecondarySave() else { return false }
        }
        openTabIDs.removeAll { $0 == id }
        if secondaryNoteID == id {
            secondaryNoteID = nil
            isNoteSplit = false
            focusedPane = .primary
            clearSecondaryDraft()
            secondaryIsDirty = false
        }
        if selectedNoteID == id {
            selectedNoteID = openTabIDs.first
            syncDraftFromSelection()
            isDirty = false
            scheduleSpellCheck(autoPopup: false)
        }
        saveStatus = "Tab closed"
        return true
    }

    func focusPane(_ pane: NoteSplitPane) {
        guard isNoteSplit || pane == .primary else { return }
        guard pane != focusedPane else {
            scheduleSpellCheck(autoPopup: false)
            return
        }
        // Keep a single source of truth when both panes show the same note.
        if isSameNoteInBothPanes {
            if focusedPane == .secondary {
                copySecondaryDraftToPrimary(includingSelection: false)
            } else {
                copyPrimaryDraftToSecondary(includingSelection: false)
            }
            // Dirty flags stay linked.
            let dirty = isDirty || secondaryIsDirty
            isDirty = dirty
            secondaryIsDirty = dirty
        }
        focusedPane = pane
        scheduleSpellCheck(autoPopup: false)
    }

    /// Enable side-by-side notes. Opens another open tab or next library note on the right.
    func openNoteSplit() {
        guard flushAllPendingSaves() else { return }
        isNoteSplit = true
        if secondaryNoteID == nil || secondaryNoteID == selectedNoteID {
            let candidate = openTabIDs.first(where: { $0 != selectedNoteID })
                ?? notes.first(where: { $0.id != selectedNoteID })?.id
            secondaryNoteID = candidate
        }
        if let sid = secondaryNoteID {
            ensureOpenTab(sid)
            if sid == selectedNoteID {
                copyPrimaryDraftToSecondary(includingSelection: false)
                secondaryIsDirty = isDirty
            } else {
                syncSecondaryDraftFromID()
                secondaryIsDirty = false
            }
        }
        focusedPane = .primary
        saveStatus = secondaryNoteID == nil ? "Split · pick a second note" : "Note split"
    }

    func closeNoteSplit() {
        if secondaryIsDirty {
            guard flushSecondarySave() else { return }
        }
        isNoteSplit = false
        secondaryNoteID = nil
        focusedPane = .primary
        clearSecondaryDraft()
        secondaryIsDirty = false
        saveStatus = "Split closed"
    }

    func toggleNoteSplit() {
        if isNoteSplit {
            closeNoteSplit()
        } else {
            openNoteSplit()
        }
    }

    /// Open `id` in the right pane (creates split).
    func openInSplit(_ id: UUID) {
        if id == selectedNoteID, isNoteSplit, secondaryNoteID == id {
            focusPane(.secondary)
            return
        }
        guard flushSecondaryIfNeeded(replacing: id) else { return }
        // If primary is a different dirty note, flush it before we only show one id on the right.
        if id != selectedNoteID, isDirty {
            guard flushPrimarySave() else { return }
        }
        isNoteSplit = true
        secondaryNoteID = id
        ensureOpenTab(id)
        if id == selectedNoteID {
            // Same file both panes: right pane mirrors left (including unsaved text).
            copyPrimaryDraftToSecondary(includingSelection: false)
            secondaryIsDirty = isDirty
            saveStatus = "Same note in split · edits stay in sync"
        } else {
            syncSecondaryDraftFromID()
            secondaryIsDirty = false
            saveStatus = "Opened in split"
        }
        focusedPane = .secondary
    }

    private func flushSecondaryIfNeeded(replacing newID: UUID) -> Bool {
        if secondaryIsDirty, secondaryNoteID != newID {
            return flushSecondarySave()
        }
        return true
    }

    func setTitle(_ value: String) {
        guard draftTitle != value else { return }
        draftTitle = value
        markDirty()
        mirrorPrimaryDraftToSecondaryIfShared(fields: .metadata)
    }

    func setBody(_ value: String) {
        // Direct set from binding without range math — editor uses applyEdit for gated changes.
        // Fallback path (undo/paste without pendingEdit): still infer a single edit so dismiss
        // stickiness matches commitEditorChange rather than prune-only.
        guard draftBody != value else { return }
        let previous = draftBody
        draftBody = value
        draftLockedSpans = LockedSpanMath.clamp(draftLockedSpans, toTextLength: (value as NSString).length)
        dismissedOccurrences = reconcileDismissedOnTextChange(
            dismissedOccurrences,
            from: previous,
            to: value
        )
        markDirty()
        mirrorPrimaryDraftToSecondaryIfShared(fields: .body)
        scheduleSpellCheck(autoPopup: false)
    }

    /// Called by editor before applying an edit. Returns false if locked text would change.
    func canEdit(range: NSRange, replacement: String) -> Bool {
        // Pure deletion of mixed content is handled by smartDelete, not canEdit.
        if replacement.isEmpty, range.length > 0, LockedSpanMath.isMixedSelection(range, spans: draftLockedSpans) {
            return true
        }
        return !LockedSpanMath.anyBlocks(draftLockedSpans, edit: range)
    }

    /// Apply text replacement that was allowed; updates locks (used by fix-all / programmatic edits).
    func applyEdit(range: NSRange, replacement: String) {
        let ns = draftBody as NSString
        guard range.location + range.length <= ns.length else { return }
        guard !LockedSpanMath.anyBlocks(draftLockedSpans, edit: range) else { return }
        draftBody = ns.replacingCharacters(in: range, with: replacement)
        draftLockedSpans = LockedSpanMath.adjusting(
            draftLockedSpans,
            edited: range,
            replacementLength: (replacement as NSString).length
        )
        draftLockedSpans = LockedSpanMath.clamp(draftLockedSpans, toTextLength: (draftBody as NSString).length)
        dismissedOccurrences = adjustDismissed(
            dismissedOccurrences,
            edited: range,
            replacementLength: (replacement as NSString).length,
            in: draftBody
        )
        let caret = range.location + (replacement as NSString).length
        selectedRange = NSRange(location: caret, length: 0)
        markDirty()
        mirrorPrimaryDraftToSecondaryIfShared(fields: .body)
        scheduleSpellCheck(autoPopup: false)
    }

    /// A1: NSTextView already applied the edit; commit body + span adjust from pre-edit spans.
    func commitEditorChange(
        newText: String,
        edited: NSRange,
        replacement: String,
        previousSpans: [LockedSpan]
    ) {
        draftBody = newText
        draftLockedSpans = LockedSpanMath.adjusting(
            previousSpans,
            edited: edited,
            replacementLength: (replacement as NSString).length
        )
        draftLockedSpans = LockedSpanMath.clamp(draftLockedSpans, toTextLength: (newText as NSString).length)
        dismissedOccurrences = adjustDismissed(
            dismissedOccurrences,
            edited: edited,
            replacementLength: (replacement as NSString).length,
            in: newText
        )
        selectedRange = NSRange(
            location: edited.location + (replacement as NSString).length,
            length: 0
        )
        markDirty()
        mirrorPrimaryDraftToSecondaryIfShared(fields: .body)
        scheduleSpellCheck(autoPopup: false)
    }

    func notifyBlockedEdit() {
        saveStatus = "Can't edit locked text — unlock first"
    }

    /// B3: delete only unlocked segments inside `range` (back-to-front).
    func smartDelete(range: NSRange) {
        let segments = LockedSpanMath.unlockedSegments(of: range, spans: draftLockedSpans)
        guard !segments.isEmpty else {
            notifyBlockedEdit()
            return
        }
        var body = draftBody
        var spans = draftLockedSpans
        var dismissals = dismissedOccurrences
        for seg in segments.sorted(by: { $0.location > $1.location }) {
            let ns = body as NSString
            guard seg.location + seg.length <= ns.length else { continue }
            body = ns.replacingCharacters(in: seg, with: "")
            spans = LockedSpanMath.adjusting(spans, edited: seg, replacementLength: 0)
            // Shift/drop dismissals per segment (same rules as locks) so text before a
            // dismissed word still keeps that occurrence dismissed after the delete.
            dismissals = adjustDismissed(dismissals, edited: seg, replacementLength: 0, in: body)
        }
        draftBody = body
        draftLockedSpans = LockedSpanMath.clamp(spans, toTextLength: (body as NSString).length)
        dismissedOccurrences = dismissals
        // Caret at start of original selection (still valid after back-to-front deletes inside range).
        let caret = min(range.location, (body as NSString).length)
        selectedRange = NSRange(location: caret, length: 0)
        markDirty()
        mirrorPrimaryDraftToSecondaryIfShared(fields: .body)
        scheduleSpellCheck(autoPopup: false)
        saveStatus = "Deleted unlocked text"
    }

    func restoreSnapshot(text: String, spans: [LockedSpan], selection: NSRange) {
        let previous = draftBody
        draftBody = text
        draftLockedSpans = spans
        selectedRange = selection
        dismissedOccurrences = reconcileDismissedOnTextChange(
            dismissedOccurrences,
            from: previous,
            to: text
        )
        markDirty()
        mirrorPrimaryDraftToSecondaryIfShared(fields: .body)
        scheduleSpellCheck(autoPopup: false)
    }

    func editorSnapshot() -> (text: String, spans: [LockedSpan], selection: NSRange) {
        (draftBody, draftLockedSpans, selectedRange)
    }

    /// B1: apply top suggestion to every current (unlocked) misspelling. Returns summary.
    @discardableResult
    func fixAllMisspellings() -> String {
        runSpellCheck(autoPopup: false)
        let plan = TextReplacementBatch.plan(misspellings: misspellings) { m in
            fillSuggestions(m).suggestions.first
        }
        guard !plan.replacements.isEmpty else {
            let msg = plan.skipped > 0 ? "Fixed 0 · skipped \(plan.skipped)" : "Nothing to fix"
            saveStatus = msg
            return msg
        }
        let sorted = plan.replacements.sorted(by: { $0.range.location > $1.range.location })
        let items = sorted.compactMap { rep -> (range: NSRange, replacement: String)? in
            guard canEdit(range: rep.range, replacement: rep.replacement) else { return nil }
            return (rep.range, rep.replacement)
        }
        if activeEditorBridge.isConnected, !items.isEmpty {
            activeEditorBridge.replaceMany(items, actionName: "Fix All")
        } else {
            for item in items {
                applyEdit(range: item.range, replacement: item.replacement)
            }
        }
        for rep in sorted {
            if items.contains(where: { $0.range == rep.range && $0.replacement == rep.replacement }) {
                _ = correctionLog.record(wrong: rep.original, correct: rep.replacement)
            }
        }
        activeSuggestion = nil
        let msg = "Fixed \(items.count) · skipped \(plan.skipped + (plan.replacements.count - items.count))"
        saveStatus = msg
        scheduleSpellCheck(autoPopup: false)
        return msg
    }

    func markDirtyFromEditor() {
        markDirty()
        scheduleSpellCheck(autoPopup: false)
    }

    func handleWordBoundary() {
        scheduleSpellCheck(autoPopup: true, delay: 0.05)
    }

    func lockSelection(label _: String? = nil) {
        guard selectedRange.length > 0 else {
            saveStatus = "Select text to lock"
            return
        }
        // Lock labels removed from UX — do not store a display label on new locks.
        draftLockedSpans = LockedSpanMath.add(draftLockedSpans, range: selectedRange, label: nil)
        markDirty()
        saveStatus = "Locked selection"
    }

    func unlockSelection() {
        draftLockedSpans = LockedSpanMath.remove(draftLockedSpans, intersecting: selectedRange)
        markDirty()
        saveStatus = "Unlocked"
    }

    func renameRegion(at index: Int, label _: String?) {
        // Labels removed from UX — keep API but clear any label.
        draftLockedSpans = LockedSpanMath.rename(draftLockedSpans, at: index, label: nil)
        markDirty()
        saveStatus = "Region updated"
    }

    func jumpToRegion(at index: Int) {
        guard draftLockedSpans.indices.contains(index) else { return }
        let span = draftLockedSpans[index]
        selectedRange = span.utf16Range
        saveStatus = "Region [\(span.location)+\(span.length)]"
    }

    /// Status-bar action: jump to first misspelling and open suggestions.
    func jumpToFirstMisspelling() {
        guard let first = misspellings.first else { return }
        let filled = fillSuggestions(first)
        selectedRange = filled.utf16Range
        activeSuggestion = filled.suggestions.isEmpty ? nil : filled
        if activeSuggestion != nil {
            saveStatus = "⌘1–⌘5 to fix “\(filled.word)”"
        } else {
            saveStatus = "Issue: \(filled.word)"
        }
    }

    func setFolder(_ value: String) {
        let n = NoteTagging.normalizeFolder(value) ?? LibraryPaths.inbox
        let display = n
        guard draftFolder != display else { return }
        let previousFolder = draftFolder
        draftFolder = display
        guard let id = selectedNoteID else {
            markDirty()
            return
        }
        // Moving files is the source of truth for folder changes. Never clear dirty
        // or claim move success if the draft could not be flushed first.
        guard flushPendingSave() else {
            draftFolder = previousFolder
            return
        }
        do {
            let moved = try store.move(id: id, toFolder: display)
            if let idx = notes.firstIndex(where: { $0.id == id }) {
                notes[idx] = moved
            }
            draftFolder = moved.folder ?? LibraryPaths.inbox
            isDirty = false
            saveStatus = "Moved to \(moved.folder ?? LibraryPaths.inbox)"
            refreshMTimes()
        } catch {
            draftFolder = previousFolder
            markDirty()
            saveStatus = "Move failed"
        }
    }

    func renameFolder(from: String, to: String) {
        let src = LibraryPaths.normalizeFolder(from)
        let dst = LibraryPaths.normalizeFolder(to)
        guard src != dst else { return }
        guard flushAllPendingSaves() else { return }
        do {
            try store.renameFolder(from: src, to: dst)
            reload()
            if selectedFolderFilter == src || selectedFolderFilter?.hasPrefix(src + "/") == true {
                if let filter = selectedFolderFilter, filter.hasPrefix(src + "/") {
                    selectedFolderFilter = dst + String(filter.dropFirst(src.count))
                } else {
                    selectedFolderFilter = dst
                }
            }
            if draftFolder == src || draftFolder.hasPrefix(src + "/") {
                draftFolder = draftFolder == src ? dst : dst + String(draftFolder.dropFirst(src.count))
            }
            if secondaryDraftFolder == src || secondaryDraftFolder.hasPrefix(src + "/") {
                secondaryDraftFolder = secondaryDraftFolder == src
                    ? dst
                    : dst + String(secondaryDraftFolder.dropFirst(src.count))
            }
            saveStatus = "Renamed folder \(src) → \(dst)"
        } catch {
            saveStatus = "Rename folder failed"
        }
    }

    /// Delete a folder: move all notes under it (nested included) into `inbox/`.
    @discardableResult
    func deleteFolder(_ raw: String) -> Int {
        let folder = LibraryPaths.normalizeFolder(raw)
        guard folder != LibraryPaths.inbox else {
            saveStatus = "Cannot delete inbox"
            return 0
        }
        guard flushAllPendingSaves() else { return 0 }
        do {
            let n = try store.deleteFolderMovingNotesToInbox(folder)
            reload()
            if selectedFolderFilter == folder || selectedFolderFilter?.hasPrefix(folder + "/") == true {
                selectedFolderFilter = nil
            }
            saveStatus = n == 0
                ? "Folder removed (empty)"
                : "Deleted folder · \(n) note(s) → inbox"
            return n
        } catch {
            saveStatus = "Delete folder failed"
            return 0
        }
    }

    /// Rename a tag globally across the library (and update open drafts/filters).
    @discardableResult
    func renameTag(from rawFrom: String, to rawTo: String) -> Int {
        let from = rawFrom.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = rawTo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !from.isEmpty, !to.isEmpty else { return 0 }
        guard from.lowercased() != to.lowercased() || from != to else {
            // Allow case-only renames via store
            return renameTagCaseOrIdentity(from: from, to: to)
        }
        guard flushAllPendingSaves() else { return 0 }
        do {
            let n = try store.rewriteTag(from: from, to: to)
            applyTagRewriteInDrafts(from: from, to: to)
            if selectedTagFilters.contains(from) {
                selectedTagFilters.remove(from)
                selectedTagFilters.insert(to)
            }
            // Case-insensitive filter cleanup
            selectedTagFilters = Set(selectedTagFilters.map { $0.lowercased() == from.lowercased() ? to : $0 })
            reloadPreservingSelection()
            saveStatus = n == 0 ? "Tag not used" : "Renamed tag “\(from)” → “\(to)” (\(n))"
            return n
        } catch {
            saveStatus = "Rename tag failed"
            return 0
        }
    }

    private func renameTagCaseOrIdentity(from: String, to: String) -> Int {
        guard flushAllPendingSaves() else { return 0 }
        do {
            let n = try store.rewriteTag(from: from, to: to)
            applyTagRewriteInDrafts(from: from, to: to)
            reloadPreservingSelection()
            saveStatus = "Renamed tag “\(from)” → “\(to)”"
            return n
        } catch {
            saveStatus = "Rename tag failed"
            return 0
        }
    }

    /// Remove a tag from every note (notes remain).
    @discardableResult
    func deleteTag(_ raw: String) -> Int {
        let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { return 0 }
        guard flushAllPendingSaves() else { return 0 }
        do {
            let n = try store.rewriteTag(from: tag, to: nil)
            applyTagRewriteInDrafts(from: tag, to: nil)
            selectedTagFilters = selectedTagFilters.filter { $0.lowercased() != tag.lowercased() }
            reloadPreservingSelection()
            saveStatus = n == 0 ? "Tag not used" : "Removed tag “\(tag)” from \(n) note(s)"
            return n
        } catch {
            saveStatus = "Delete tag failed"
            return 0
        }
    }

    private func applyTagRewriteInDrafts(from: String, to: String?) {
        let fromKey = from.lowercased()
        func rewrite(_ text: String) -> String {
            var tags = NoteTagging.parseTagString(text)
            tags = tags.filter { $0.lowercased() != fromKey }
            if let to, !to.isEmpty { tags.append(to) }
            return NoteTagging.tagsDisplayString(NoteTagging.normalizeTags(tags))
        }
        draftTagsText = rewrite(draftTagsText)
        secondaryDraftTagsText = rewrite(secondaryDraftTagsText)
    }

    private func reloadPreservingSelection() {
        let primary = selectedNoteID
        let secondary = secondaryNoteID
        let tabs = openTabIDs
        let split = isNoteSplit
        let focus = focusedPane
        do {
            notes = try store.loadAll()
            openTabIDs = tabs.filter { id in notes.contains(where: { $0.id == id }) }
            if let primary, notes.contains(where: { $0.id == primary }) {
                selectedNoteID = primary
            } else {
                selectedNoteID = openTabIDs.first ?? regularNotes.first?.id
            }
            if let secondary, notes.contains(where: { $0.id == secondary }) {
                secondaryNoteID = secondary
            } else {
                secondaryNoteID = nil
                if split { isNoteSplit = secondaryNoteID != nil }
            }
            isNoteSplit = split && secondaryNoteID != nil
            focusedPane = focus
            syncDraftFromSelection()
            if isNoteSplit, secondaryNoteID != nil {
                syncSecondaryDraftFromID()
            }
            isDirty = false
            secondaryIsDirty = false
            saveStatus = "Ready"
            scheduleSpellCheck(autoPopup: false)
        } catch {
            saveStatus = "Reload failed"
        }
    }

    func revealSelectedInFinder() {
        guard let id = selectedNoteID, let url = store.fileURL(for: id) else {
            saveStatus = "No file to reveal"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func revealLibraryInFinder() {
        NSWorkspace.shared.open(store.libraryRoot)
    }

    func emptyTrash() {
        do {
            try store.emptyTrash()
            saveStatus = "Trash emptied"
        } catch {
            saveStatus = "Empty trash failed"
        }
    }

    var trashCount: Int { store.trashItemCount() }

    @discardableResult
    func importMarkdownDirectory(_ url: URL, destFolder: String?) -> Int {
        // Selection will switch to the first import — abort if current draft cannot be saved.
        guard flushPendingSave() else { return 0 }
        do {
            let imported = try store.importMarkdownFolder(from: url, destFolder: destFolder)
            if !imported.isEmpty {
                notes.insert(contentsOf: imported, at: 0)
                notes.sort { $0.updatedAt > $1.updatedAt }
                if let first = imported.first {
                    selectedNoteID = first.id
                    syncDraftFromSelection()
                    isDirty = false
                }
            }
            saveStatus = "Imported \(imported.count) markdown file(s)"
            refreshMTimes()
            return imported.count
        } catch {
            saveStatus = "Import folder failed"
            return 0
        }
    }

    @discardableResult
    func backupLibrary() -> URL? {
        do {
            let zip = try store.createBackupZip()
            saveStatus = "Backup: \(zip.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([zip])
            return zip
        } catch {
            saveStatus = "Backup failed"
            return nil
        }
    }

    /// Fuzzy quick-switcher results (title + path).
    func quickSwitcherResults(limit: Int = 30) -> [Note] {
        let q = quickSwitcherQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = notes.sorted { $0.updatedAt > $1.updatedAt }
        guard !q.isEmpty else { return Array(base.prefix(limit)) }
        let scored: [(Note, Int)] = base.compactMap { note in
            let title = note.displayTitle.lowercased()
            let path = (store.relativePath(for: note.id) ?? note.folder ?? "").lowercased()
            var score = 0
            if title == q { score += 100 }
            else if title.hasPrefix(q) { score += 80 }
            else if title.contains(q) { score += 50 }
            if path.contains(q) { score += 40 }
            for part in q.split(separator: " ") {
                let p = String(part)
                if title.contains(p) { score += 10 }
                if path.contains(p) { score += 8 }
            }
            return score > 0 ? (note, score) : nil
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    func openQuickSwitcher() {
        quickSwitcherQuery = ""
        showQuickSwitcher = true
    }

    func closeQuickSwitcher() {
        showQuickSwitcher = false
        quickSwitcherQuery = ""
    }

    func selectFromQuickSwitcher(_ id: UUID) {
        guard flushPendingSave() else { return }
        _ = select(id: id, force: true)
        closeQuickSwitcher()
    }

    func setTagsText(_ value: String) {
        guard draftTagsText != value else { return }
        draftTagsText = value
        markDirty()
    }

    func toggleTagFilter(_ tag: String) {
        if selectedTagFilters.contains(tag) {
            selectedTagFilters.remove(tag)
        } else {
            selectedTagFilters.insert(tag)
        }
    }

    func clearTagFilters() {
        selectedTagFilters.removeAll()
    }

    // MARK: - Export / Import

    func exportTemplatesJSON(ids: Set<UUID>? = nil) throws -> Data {
        let list = notes.filter { $0.isTemplate && (ids == nil || ids!.contains($0.id)) }
        let pack = TemplatePack.pack(from: list)
        return try TemplatePack.encodeJSON(pack)
    }

    func exportTemplatesMarkdown(ids: Set<UUID>? = nil) -> [(fileName: String, contents: String)] {
        let list = notes.filter { $0.isTemplate && (ids == nil || ids!.contains($0.id)) }
        var used = Set<String>()
        var out: [(String, String)] = []
        for note in list {
            var name = TemplatePack.safeFileName(for: note.displayTitle)
            if used.contains(name) {
                let base = name.replacingOccurrences(of: ".md", with: "")
                name = "\(base)-\(note.id.uuidString.prefix(6)).md"
            }
            used.insert(name)
            let item = TemplatePackItem(note: note)
            out.append((name, TemplatePack.exportMarkdown(item)))
        }
        return out
    }

    /// Parse one file into notes (no UI / no spell-check). Safe off main actor for pure parsing;
    /// call `commitImportedNotes` on main to attach.
    nonisolated static func parseImportFile(data: Data, pathExtension: String) throws -> [Note] {
        let ext = pathExtension.lowercased()
        if ext == "json" {
            let pack = try TemplatePack.decodeJSON(data)
            guard !pack.templates.isEmpty else { throw TemplatePackError.emptyPack }
            return pack.templates.map { item in
                var note = item.asNewNote()
                note.isTemplate = true
                if !note.tags.contains(where: { $0.lowercased() == "imported" }) {
                    note.tags = NoteTagging.normalizeTags(note.tags + ["imported"])
                }
                return note
            }
        }
        if ext == "md" || ext == "markdown" || ext == "txt" {
            guard let text = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1) else {
                throw TemplatePackError.invalidMarkdown
            }
            return [try noteFromMarkdownText(text)]
        }
        if let pack = try? TemplatePack.decodeJSON(data), !pack.templates.isEmpty {
            return pack.templates.map { item in
                var note = item.asNewNote()
                note.isTemplate = true
                if !note.tags.contains(where: { $0.lowercased() == "imported" }) {
                    note.tags = NoteTagging.normalizeTags(note.tags + ["imported"])
                }
                return note
            }
        }
        if let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{"),
               (trimmed.contains("bispell-template-pack") || trimmed.contains("\"templates\"")) {
                let pack = try TemplatePack.decodeJSON(data)
                guard !pack.templates.isEmpty else { throw TemplatePackError.emptyPack }
                return pack.templates.map { item in
                    var note = item.asNewNote()
                    note.isTemplate = true
                    if !note.tags.contains(where: { $0.lowercased() == "imported" }) {
                        note.tags = NoteTagging.normalizeTags(note.tags + ["imported"])
                    }
                    return note
                }
            }
            return [try noteFromMarkdownText(text)]
        }
        throw TemplatePackError.invalidFormat
    }

    nonisolated private static func noteFromMarkdownText(_ text: String) throws -> Note {
        var item = try TemplatePack.parseMarkdown(text)
        if !item.tags.contains(where: { $0.lowercased() == "imported" }) {
            item.tags = NoteTagging.normalizeTags(item.tags + ["imported"])
        }
        return item.asNewNote()
    }

    /// Single-file import (kept for callers); prefer batch path for multi-file.
    func importTemplateFile(data: Data, pathExtension: String) throws -> Int {
        let parsed = try Self.parseImportFile(data: data, pathExtension: pathExtension)
        return try commitImportedNotes(parsed, selectFirst: true)
    }

    /// Persist many notes once, one list update, one selection, delayed spell-check.
    @discardableResult
    func commitImportedNotes(_ newNotes: [Note], selectFirst: Bool) throws -> Int {
        guard !newNotes.isEmpty else { return 0 }
        // Selection will switch to the first import — abort if current draft cannot be saved.
        if selectFirst {
            guard flushPendingSave() else { return 0 }
        }
        try store.saveAll(newNotes)
        // Prepend without re-sorting the whole library on every insert.
        notes.insert(contentsOf: newNotes, at: 0)
        notes.sort { $0.updatedAt > $1.updatedAt }
        if selectFirst, let first = newNotes.first {
            selectedNoteID = first.id
            focusedPane = .primary
            ensureOpenTab(first.id)
            syncDraftFromSelection()
            isDirty = false
            // Long delay so the UI settles before Hunspell scans a large body.
            let delay = (draftBody as NSString).length > Self.fullSpellCheckUTF16Limit ? 1.2 : 0.4
            scheduleSpellCheck(autoPopup: false, delay: delay)
        }
        let templates = newNotes.filter(\.isTemplate).count
        let regular = newNotes.count - templates
        if templates > 0, regular > 0 {
            saveStatus = "Imported \(newNotes.count) (\(templates) templates, \(regular) notes)"
        } else if templates > 0 {
            saveStatus = "Imported \(templates) template(s)"
        } else {
            saveStatus = "Imported \(regular) note(s)"
        }
        return newNotes.count
    }

    func importTemplatePackJSON(_ data: Data) throws -> Int {
        try importTemplateFile(data: data, pathExtension: "json")
    }

    func importTemplateMarkdown(_ text: String) throws -> Int {
        try commitImportedNotes([try Self.noteFromMarkdownText(text)], selectFirst: true)
    }

    func cycleEditorMode() {
        switch editorMode {
        case .source: editorMode = .split
        case .split: editorMode = .preview
        case .preview: editorMode = .source
        }
    }

    func save() {
        if isSameNoteInBothPanes {
            // One file: persist focused pane once, then mirror.
            if focusedPane == .secondary {
                persistSecondaryDraftNow()
            } else {
                persistDraftNow()
            }
            return
        }
        if focusedPane == .secondary, isNoteSplit {
            persistSecondaryDraftNow()
        } else {
            persistDraftNow()
        }
    }

    /// Flush dirty draft for the focused pane (and, for safety, both panes when split).
    /// Returns `false` if still dirty after attempting save
    /// (callers must abort navigation/rebind/rename so the draft is not discarded).
    @discardableResult
    func flushPendingSave() -> Bool {
        flushAllPendingSaves()
    }

    @discardableResult
    func flushAllPendingSaves() -> Bool {
        // Critical: when both panes show the same note, never write primary then
        // secondary (or vice versa) from diverged drafts — one write wins.
        if isSameNoteInBothPanes {
            if isDirty || secondaryIsDirty {
                // Prefer the focused pane as the source of truth.
                if focusedPane == .secondary {
                    persistSecondaryDraftNow()
                } else {
                    persistDraftNow()
                }
            }
            return !isDirty && !secondaryIsDirty
        }
        let primaryOK = flushPrimarySave()
        let secondaryOK = flushSecondarySave()
        return primaryOK && secondaryOK
    }

    @discardableResult
    func flushPrimarySave() -> Bool {
        if isSameNoteInBothPanes {
            return flushAllPendingSaves()
        }
        if isDirty { persistDraftNow() }
        return !isDirty
    }

    @discardableResult
    func flushSecondarySave() -> Bool {
        if isSameNoteInBothPanes {
            return flushAllPendingSaves()
        }
        guard isNoteSplit, secondaryNoteID != nil else {
            secondaryIsDirty = false
            return true
        }
        if secondaryIsDirty { persistSecondaryDraftNow() }
        return !secondaryIsDirty
    }

    func applySuggestion(_ suggestion: String, for misspelling: Misspelling) {
        let range = misspelling.utf16Range
        let onSecondary = isNoteSplit && focusedPane == .secondary
        if onSecondary {
            guard canEditSecondary(range: range, replacement: suggestion) else {
                saveStatus = "Can't edit locked text"
                return
            }
        } else {
            guard canEdit(range: range, replacement: suggestion) else {
                saveStatus = "Can't edit locked text"
                return
            }
        }
        let wrong = misspelling.word
        if activeEditorBridge.isConnected {
            activeEditorBridge.replace(range: range, with: suggestion, actionName: "Spelling")
        } else if onSecondary {
            // Apply into secondary body without primary draft helpers.
            let ns = secondaryDraftBody as NSString
            guard range.location + range.length <= ns.length else { return }
            secondaryDraftBody = ns.replacingCharacters(in: range, with: suggestion)
            secondaryDraftLockedSpans = LockedSpanMath.adjusting(
                secondaryDraftLockedSpans,
                edited: range,
                replacementLength: (suggestion as NSString).length
            )
            markSecondaryDirty()
        } else {
            applyEdit(range: range, replacement: suggestion)
        }
        if onSecondary {
            secondaryActiveSuggestion = nil
        } else {
            activeSuggestion = nil
        }
        _ = correctionLog.record(wrong: wrong, correct: suggestion)
        saveStatus = "Fixed “\(wrong)” → \(suggestion)"
    }

    func dismissSuggestions() {
        if let active = activeSuggestion {
            recordDismissed(active)
            // Drop from live list so status-bar jump / nearest can't re-popup this instance.
            misspellings.removeAll {
                $0.utf16Range == active.utf16Range && $0.word == active.word
            }
            if isSameNoteInBothPanes {
                secondaryMisspellings.removeAll {
                    $0.utf16Range == active.utf16Range && $0.word == active.word
                }
                if let secondaryActive = secondaryActiveSuggestion,
                   secondaryActive.utf16Range == active.utf16Range,
                   secondaryActive.word == active.word {
                    secondaryActiveSuggestion = nil
                }
            }
        }
        activeSuggestion = nil
    }

    /// Dismiss secondary-pane suggestion popup and remember that occurrence for this note session.
    func dismissSecondarySuggestions() {
        if let active = secondaryActiveSuggestion {
            // Secondary uses its own misspellings list when not sharing the same note;
            // still record on shared primary dismiss store when same note.
            recordDismissed(active)
            secondaryMisspellings.removeAll {
                $0.utf16Range == active.utf16Range && $0.word == active.word
            }
            // Same note both panes: keep primary list in sync so jump/nearest stay dismissed.
            if isSameNoteInBothPanes {
                misspellings.removeAll {
                    $0.utf16Range == active.utf16Range && $0.word == active.word
                }
                if let primaryActive = activeSuggestion,
                   primaryActive.utf16Range == active.utf16Range,
                   primaryActive.word == active.word {
                    activeSuggestion = nil
                }
            }
        }
        secondaryActiveSuggestion = nil
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
        var base = list
        if let folder = selectedFolderFilter {
            // Match exact folder or nested children
            base = base.filter { note in
                guard let f = note.folder else { return folder == LibraryPaths.inbox }
                return f == folder || f.hasPrefix(folder + "/")
            }
        }
        if !selectedTagFilters.isEmpty {
            base = base.filter { note in
                let noteTags = Set(note.tags.map { $0.lowercased() })
                return selectedTagFilters.allSatisfy { noteTags.contains($0.lowercased()) }
            }
        }
        if !q.isEmpty {
            base = base.filter {
                let path = store.relativePath(for: $0.id) ?? $0.folder ?? ""
                return $0.displayTitle.localizedCaseInsensitiveContains(q)
                    || $0.body.localizedCaseInsensitiveContains(q)
                    || ($0.folder?.localizedCaseInsensitiveContains(q) ?? false)
                    || path.localizedCaseInsensitiveContains(q)
                    || $0.tags.contains(where: { $0.localizedCaseInsensitiveContains(q) })
            }
        }
        switch sortMode {
        case .updated:
            base.sort { $0.updatedAt > $1.updatedAt }
        case .title:
            base.sort {
                $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
            }
        case .path:
            base.sort {
                let p0 = store.relativePath(for: $0.id) ?? $0.folder ?? ""
                let p1 = store.relativePath(for: $1.id) ?? $1.folder ?? ""
                let c = p0.localizedCaseInsensitiveCompare(p1)
                if c != .orderedSame { return c == .orderedAscending }
                return $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
            }
        }
        return base
    }

    private func markDirty() {
        isDirty = true
        if isSameNoteInBothPanes {
            secondaryIsDirty = true
        }
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
            draftFolder = note.folder ?? ""
            draftTagsText = NoteTagging.tagsDisplayString(note.tags)
            selectedRange = NSRange(location: (note.body as NSString).length, length: 0)
            ensureOpenTab(note.id)
        } else {
            draftTitle = ""
            draftBody = ""
            draftLockedSpans = []
            draftIsTemplate = false
            draftFolder = ""
            draftTagsText = ""
            selectedRange = NSRange(location: 0, length: 0)
        }
        misspellings = []
        activeSuggestion = nil
        // Dismissals are per open-note session.
        dismissedOccurrences = []
    }

    private func syncSecondaryDraftFromID() {
        if let note = secondaryNote {
            secondaryDraftTitle = note.title
            secondaryDraftBody = note.body
            secondaryDraftLockedSpans = note.lockedSpans
            secondaryDraftIsTemplate = note.isTemplate
            secondaryDraftFolder = note.folder ?? ""
            secondaryDraftTagsText = NoteTagging.tagsDisplayString(note.tags)
            secondarySelectedRange = NSRange(location: (note.body as NSString).length, length: 0)
            ensureOpenTab(note.id)
        } else {
            clearSecondaryDraft()
        }
        secondaryMisspellings = []
        secondaryActiveSuggestion = nil
    }

    private func clearSecondaryDraft() {
        secondaryDraftTitle = ""
        secondaryDraftBody = ""
        secondaryDraftLockedSpans = []
        secondaryDraftIsTemplate = false
        secondaryDraftFolder = ""
        secondaryDraftTagsText = ""
        secondarySelectedRange = NSRange(location: 0, length: 0)
        secondaryMisspellings = []
        secondaryActiveSuggestion = nil
    }

    var secondaryTitleBinding: Binding<String> {
        Binding(
            get: { self.secondaryDraftTitle },
            set: { self.setSecondaryTitle($0) }
        )
    }

    var secondaryBodyBinding: Binding<String> {
        Binding(
            get: { self.secondaryDraftBody },
            set: { self.setSecondaryBody($0) }
        )
    }

    func setSecondaryTitle(_ value: String) {
        guard secondaryDraftTitle != value else { return }
        secondaryDraftTitle = value
        markSecondaryDirty()
        mirrorSecondaryDraftToPrimaryIfShared(fields: .metadata)
    }

    func setSecondaryBody(_ value: String) {
        guard secondaryDraftBody != value else { return }
        let previous = secondaryDraftBody
        secondaryDraftBody = value
        secondaryDraftLockedSpans = LockedSpanMath.clamp(
            secondaryDraftLockedSpans,
            toTextLength: (value as NSString).length
        )
        // Same-note split: dismissals live on the shared session — infer edit like primary setBody.
        if isSameNoteInBothPanes {
            dismissedOccurrences = reconcileDismissedOnTextChange(
                dismissedOccurrences,
                from: previous,
                to: value
            )
        }
        markSecondaryDirty()
        mirrorSecondaryDraftToPrimaryIfShared(fields: .body)
        if isSameNoteInBothPanes {
            scheduleSpellCheck(autoPopup: false)
        }
    }

    func setSecondaryFolder(_ value: String) {
        let n = NoteTagging.normalizeFolder(value) ?? LibraryPaths.inbox
        guard secondaryDraftFolder != n else { return }
        let previous = secondaryDraftFolder
        secondaryDraftFolder = n
        guard let id = secondaryNoteID else {
            markSecondaryDirty()
            return
        }
        guard flushSecondarySave() else {
            secondaryDraftFolder = previous
            return
        }
        // Primary may also be dirty — folder move only for secondary note.
        do {
            let moved = try store.move(id: id, toFolder: n)
            if let idx = notes.firstIndex(where: { $0.id == id }) {
                notes[idx] = moved
            }
            secondaryDraftFolder = moved.folder ?? LibraryPaths.inbox
            secondaryIsDirty = false
            saveStatus = "Moved to \(moved.folder ?? LibraryPaths.inbox)"
            refreshMTimes()
        } catch {
            secondaryDraftFolder = previous
            markSecondaryDirty()
            saveStatus = "Move failed"
        }
    }

    func setSecondaryTagsText(_ value: String) {
        guard secondaryDraftTagsText != value else { return }
        secondaryDraftTagsText = value
        markSecondaryDirty()
        mirrorSecondaryDraftToPrimaryIfShared(fields: .metadata)
    }

    func markSecondaryDirtyFromEditor() {
        markSecondaryDirty()
    }

    func canEditSecondary(range: NSRange, replacement: String) -> Bool {
        if replacement.isEmpty, range.length > 0,
           LockedSpanMath.isMixedSelection(range, spans: secondaryDraftLockedSpans) {
            return true
        }
        return !LockedSpanMath.anyBlocks(secondaryDraftLockedSpans, edit: range)
    }

    func commitSecondaryEditorChange(
        newText: String,
        edited: NSRange,
        replacement: String,
        previousSpans: [LockedSpan]
    ) {
        secondaryDraftBody = newText
        secondaryDraftLockedSpans = LockedSpanMath.adjusting(
            previousSpans,
            edited: edited,
            replacementLength: (replacement as NSString).length
        )
        secondaryDraftLockedSpans = LockedSpanMath.clamp(
            secondaryDraftLockedSpans,
            toTextLength: (newText as NSString).length
        )
        // Same-note split: shift/drop dismissals with the edit (mirrors primary commitEditorChange).
        if isSameNoteInBothPanes {
            dismissedOccurrences = adjustDismissed(
                dismissedOccurrences,
                edited: edited,
                replacementLength: (replacement as NSString).length,
                in: newText
            )
        }
        secondarySelectedRange = NSRange(
            location: edited.location + (replacement as NSString).length,
            length: 0
        )
        markSecondaryDirty()
        mirrorSecondaryDraftToPrimaryIfShared(fields: .body)
        if isSameNoteInBothPanes {
            scheduleSpellCheck(autoPopup: false)
        }
    }

    func smartDeleteSecondary(range: NSRange) {
        let segments = LockedSpanMath.unlockedSegments(of: range, spans: secondaryDraftLockedSpans)
        guard !segments.isEmpty else {
            saveStatus = "Can't edit locked text — unlock first"
            return
        }
        var body = secondaryDraftBody
        var spans = secondaryDraftLockedSpans
        var dismissals = isSameNoteInBothPanes ? dismissedOccurrences : []
        for seg in segments.sorted(by: { $0.location > $1.location }) {
            let ns = body as NSString
            guard seg.location + seg.length <= ns.length else { continue }
            body = ns.replacingCharacters(in: seg, with: "")
            spans = LockedSpanMath.adjusting(spans, edited: seg, replacementLength: 0)
            if isSameNoteInBothPanes {
                dismissals = adjustDismissed(dismissals, edited: seg, replacementLength: 0, in: body)
            }
        }
        secondaryDraftBody = body
        secondaryDraftLockedSpans = LockedSpanMath.clamp(spans, toTextLength: (body as NSString).length)
        if isSameNoteInBothPanes {
            dismissedOccurrences = dismissals
        }
        let caret = min(range.location, (body as NSString).length)
        secondarySelectedRange = NSRange(location: caret, length: 0)
        markSecondaryDirty()
        mirrorSecondaryDraftToPrimaryIfShared(fields: .body)
        if isSameNoteInBothPanes {
            scheduleSpellCheck(autoPopup: false)
        }
        saveStatus = "Deleted unlocked text"
    }

    func restoreSecondarySnapshot(text: String, spans: [LockedSpan], selection: NSRange) {
        let previous = secondaryDraftBody
        secondaryDraftBody = text
        secondaryDraftLockedSpans = spans
        secondarySelectedRange = selection
        if isSameNoteInBothPanes {
            dismissedOccurrences = reconcileDismissedOnTextChange(
                dismissedOccurrences,
                from: previous,
                to: text
            )
        }
        markSecondaryDirty()
        mirrorSecondaryDraftToPrimaryIfShared(fields: .body)
        if isSameNoteInBothPanes {
            scheduleSpellCheck(autoPopup: false)
        }
    }

    private func markSecondaryDirty() {
        secondaryIsDirty = true
        if isSameNoteInBothPanes {
            isDirty = true
        }
        if saveStatus != "Save failed" {
            saveStatus = "Unsaved"
        }
    }

    private enum SharedMirrorFields {
        case body
        case metadata
        case all
    }

    /// Copy primary draft → secondary (same note only, unless forced via callers).
    private func copyPrimaryDraftToSecondary(includingSelection: Bool) {
        secondaryDraftTitle = draftTitle
        secondaryDraftBody = draftBody
        secondaryDraftLockedSpans = draftLockedSpans
        secondaryDraftIsTemplate = draftIsTemplate
        secondaryDraftFolder = draftFolder
        secondaryDraftTagsText = draftTagsText
        if includingSelection {
            secondarySelectedRange = selectedRange
        }
    }

    private func copySecondaryDraftToPrimary(includingSelection: Bool) {
        draftTitle = secondaryDraftTitle
        draftBody = secondaryDraftBody
        draftLockedSpans = secondaryDraftLockedSpans
        draftIsTemplate = secondaryDraftIsTemplate
        draftFolder = secondaryDraftFolder
        draftTagsText = secondaryDraftTagsText
        if includingSelection {
            selectedRange = secondarySelectedRange
        }
    }

    private func mirrorPrimaryDraftToSecondaryIfShared(fields: SharedMirrorFields) {
        guard isSameNoteInBothPanes else { return }
        switch fields {
        case .body:
            secondaryDraftBody = draftBody
            secondaryDraftLockedSpans = draftLockedSpans
        case .metadata:
            secondaryDraftTitle = draftTitle
            secondaryDraftFolder = draftFolder
            secondaryDraftTagsText = draftTagsText
            secondaryDraftIsTemplate = draftIsTemplate
        case .all:
            copyPrimaryDraftToSecondary(includingSelection: false)
        }
        secondaryIsDirty = isDirty
    }

    private func mirrorSecondaryDraftToPrimaryIfShared(fields: SharedMirrorFields) {
        guard isSameNoteInBothPanes else { return }
        switch fields {
        case .body:
            draftBody = secondaryDraftBody
            draftLockedSpans = secondaryDraftLockedSpans
        case .metadata:
            draftTitle = secondaryDraftTitle
            draftFolder = secondaryDraftFolder
            draftTagsText = secondaryDraftTagsText
            draftIsTemplate = secondaryDraftIsTemplate
        case .all:
            copySecondaryDraftToPrimary(includingSelection: false)
        }
        isDirty = secondaryIsDirty
    }

    private func persistSecondaryDraftNow() {
        guard let id = secondaryNoteID,
              var note = notes.first(where: { $0.id == id }) else {
            secondaryIsDirty = false
            return
        }
        // When both panes share this note, secondary is authoritative if we got here
        // from secondary focus / flush preference — keep primary in lockstep first.
        if isSameNoteInBothPanes {
            copySecondaryDraftToPrimary(includingSelection: false)
        }
        let title = secondaryDraftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        note.title = title.isEmpty
            ? (secondaryDraftIsTemplate ? "Untitled template" : "Untitled")
            : title
        note.body = secondaryDraftBody
        note.lockedSpans = LockedSpanMath.clamp(
            secondaryDraftLockedSpans,
            toTextLength: (secondaryDraftBody as NSString).length
        )
        note.isTemplate = secondaryDraftIsTemplate
        note.folder = NoteTagging.normalizeFolder(secondaryDraftFolder)
            ?? (secondaryDraftIsTemplate ? LibraryPaths.templates : LibraryPaths.inbox)
        note.tags = NoteTagging.parseTagString(secondaryDraftTagsText)
        note.updatedAt = Date()
        do {
            try store.save(note)
            if let idx = notes.firstIndex(where: { $0.id == id }) {
                notes[idx] = note
            }
            if let all = try? store.loadAll(), let saved = all.first(where: { $0.id == id }) {
                if let idx = notes.firstIndex(where: { $0.id == id }) {
                    notes[idx] = saved
                }
                secondaryDraftFolder = saved.folder ?? LibraryPaths.inbox
                if isSameNoteInBothPanes {
                    draftFolder = secondaryDraftFolder
                }
            }
            secondaryIsDirty = false
            if isSameNoteInBothPanes {
                isDirty = false
                copySecondaryDraftToPrimary(includingSelection: false)
            }
            saveStatus = "Saved"
            refreshMTimes()
        } catch {
            saveStatus = "Save failed"
        }
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
        let folder = NoteTagging.normalizeFolder(draftFolder) ?? (draftIsTemplate ? LibraryPaths.templates : LibraryPaths.inbox)
        note.folder = folder
        note.tags = NoteTagging.parseTagString(draftTagsText)
        note.updatedAt = Date()
        do {
            // If folder changed vs stored ref, move first
            if let ref = store.fileRef(for: id), ref.folder != folder {
                note = try store.move(id: id, toFolder: folder)
                note.title = title.isEmpty ? (draftIsTemplate ? "Untitled template" : "Untitled") : title
                note.body = draftBody
                note.isTemplate = draftIsTemplate
                note.lockedSpans = LockedSpanMath.clamp(draftLockedSpans, toTextLength: (draftBody as NSString).length)
                note.tags = NoteTagging.parseTagString(draftTagsText)
                note.updatedAt = Date()
            }
            try store.save(note)
            // Re-find index after sort / possible reorder
            if let idx = notes.firstIndex(where: { $0.id == id }) {
                notes[idx] = note
            } else {
                notes[index] = note
            }
            notes.sort { $0.updatedAt > $1.updatedAt }
            draftFolder = note.folder ?? folder
            isDirty = false
            if isSameNoteInBothPanes {
                secondaryIsDirty = false
                copyPrimaryDraftToSecondary(includingSelection: false)
            } else if secondaryNoteID == id {
                // Secondary pane was showing this note under a different layout — keep it current.
                secondaryIsDirty = false
                syncSecondaryDraftFromID()
            }
            saveStatus = "Saved"
            refreshMTimes()
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
        // Preview-only: no need to spell-check the whole document constantly.
        if editorMode == .preview {
            return
        }
        let text = draftBody
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            misspellings = []
            activeSuggestion = nil
            return
        }
        // Drop dismissals whose text no longer sits at the recorded range.
        dismissedOccurrences = pruneDismissed(dismissedOccurrences, in: text)
        // Large markdown: near-caret only keeps UI responsive after import/open.
        let utf16Len = (text as NSString).length
        let nearOnly = utf16Len > Self.fullSpellCheckUTF16Limit
        let result = engine.check(
            text: text,
            caretUTF16: selectedRange.location,
            nearCaretOnly: nearOnly
        )
        // Ignore issues inside locked spans (templates shouldn't nag) and
        // previously dismissed occurrences still present on this page.
        misspellings = result.misspellings.filter { miss in
            !LockedSpanMath.anyBlocks(draftLockedSpans, edit: miss.utf16Range)
                && !isDismissed(miss)
        }

        guard autoPopup else {
            if let active = activeSuggestion {
                if isDismissed(active) {
                    activeSuggestion = nil
                } else if let still = misspellings.first(where: {
                    $0.utf16Range == active.utf16Range && $0.word == active.word
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

    private func recordDismissed(_ misspelling: Misspelling) {
        let entry = DismissedMisspelling(misspelling)
        if !dismissedOccurrences.contains(where: { $0.matches(misspelling) }) {
            dismissedOccurrences.append(entry)
        }
    }

    private func isDismissed(_ misspelling: Misspelling) -> Bool {
        dismissedOccurrences.contains { $0.matches(misspelling) }
    }

    /// When the body changes without an explicit edit range (binding / undo / paste fallback),
    /// infer a single contiguous UTF-16 edit and shift dismissals like `commitEditorChange`.
    private func reconcileDismissedOnTextChange(
        _ items: [DismissedMisspelling],
        from previous: String,
        to newText: String
    ) -> [DismissedMisspelling] {
        guard !items.isEmpty else { return items }
        guard !previous.isEmpty else {
            return pruneDismissed(items, in: newText)
        }
        if let edit = Self.inferSingleEdit(from: previous, to: newText) {
            return adjustDismissed(
                items,
                edited: edit.edited,
                replacementLength: edit.replacementLength,
                in: newText
            )
        }
        return pruneDismissed(items, in: newText)
    }

    /// Infer a single contiguous UTF-16 edit between two strings (common prefix + common suffix).
    private static func inferSingleEdit(
        from old: String,
        to new: String
    ) -> (edited: NSRange, replacementLength: Int)? {
        let oldNS = old as NSString
        let newNS = new as NSString
        let oldLen = oldNS.length
        let newLen = newNS.length
        if oldLen == 0, newLen == 0 { return nil }

        var prefix = 0
        let minLen = min(oldLen, newLen)
        while prefix < minLen, oldNS.character(at: prefix) == newNS.character(at: prefix) {
            prefix += 1
        }

        var oldEnd = oldLen
        var newEnd = newLen
        while oldEnd > prefix, newEnd > prefix,
              oldNS.character(at: oldEnd - 1) == newNS.character(at: newEnd - 1) {
            oldEnd -= 1
            newEnd -= 1
        }

        return (
            edited: NSRange(location: prefix, length: oldEnd - prefix),
            replacementLength: newEnd - prefix
        )
    }

    /// Shift or drop dismissed occurrences after a text edit (same rules as lock adjusting).
    private func adjustDismissed(
        _ items: [DismissedMisspelling],
        edited: NSRange,
        replacementLength: Int,
        in text: String
    ) -> [DismissedMisspelling] {
        let delta = replacementLength - edited.length
        let editEnd = edited.location + edited.length
        var result: [DismissedMisspelling] = []
        for item in items {
            let spanEnd = item.location + item.length
            if editEnd <= item.location {
                // Edit entirely before this occurrence — shift.
                result.append(DismissedMisspelling(
                    location: item.location + delta,
                    length: item.length,
                    word: item.word
                ))
            } else if edited.location >= spanEnd {
                // Edit entirely after — keep.
                result.append(item)
            }
            // Overlap / replace of the dismissed instance: drop so a retyped word can re-flag.
        }
        return pruneDismissed(result, in: text)
    }

    private func pruneDismissed(_ items: [DismissedMisspelling], in text: String) -> [DismissedMisspelling] {
        let ns = text as NSString
        return items.filter { item in
            guard item.length > 0,
                  item.location >= 0,
                  item.location + item.length <= ns.length else { return false }
            return ns.substring(with: item.utf16Range) == item.word
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
        var filled = misspelling
        if filled.suggestions.isEmpty {
            filled = engine.withSuggestions(filled)
        }
        filled.suggestions = correctionLog.rankSuggestions(filled.suggestions, wrong: filled.word)
        return filled
    }

    // MARK: - Disk watch (external edits)

    private func startDiskWatch() {
        diskWatchTimer?.invalidate()
        diskWatchTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkDiskChanges()
            }
        }
        refreshMTimes()
    }

    private func refreshMTimes() {
        var map: [UUID: Date] = [:]
        for n in notes {
            if let d = store.modificationDate(for: n.id) {
                map[n.id] = d
            }
        }
        knownMTimes = map
    }

    private func checkDiskChanges() {
        guard !isDirty, !isApplyingDiskReload else { return }
        guard let id = selectedNoteID else {
            // Opportunistic: if file count changed, reload list
            return
        }
        guard let diskDate = store.modificationDate(for: id) else { return }
        if let known = knownMTimes[id], diskDate <= known.addingTimeInterval(0.5) {
            return
        }
        // External change — reload note from disk
        isApplyingDiskReload = true
        defer { isApplyingDiskReload = false }
        do {
            if let reloaded = try store.reloadNote(id: id),
               let idx = notes.firstIndex(where: { $0.id == id }) {
                notes[idx] = reloaded
                if selectedNoteID == id {
                    syncDraftFromSelection()
                    scheduleSpellCheck(autoPopup: false)
                    saveStatus = "Reloaded from disk"
                }
            }
            refreshMTimes()
        } catch {
            // ignore
        }
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
