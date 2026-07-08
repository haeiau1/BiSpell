import SwiftUI
import AppKit
import BiSpellCore

struct NotesRootView: View {
    @ObservedObject var viewModel: NotesViewModel
    @ObservedObject var appearance: NotesAppearanceController
    @Environment(\.colorScheme) private var colorScheme

    @State private var confirmDelete = false
    @State private var pendingSelection: UUID?
    @State private var showDirtySwitchAlert = false
    @State private var showDirtyNewAlert = false
    @State private var pendingNewAsTemplate = false
    @State private var pendingTemplateID: UUID?
    @State private var showDirtyFromTemplateAlert = false

    private var colors: NotesTheme.Colors {
        appearance.colors(colorScheme: colorScheme)
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationTitle("BiSpell Notes")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    ForEach(NotesTheme.allCases) { theme in
                        Button {
                            appearance.theme = theme
                        } label: {
                            HStack {
                                Text(theme.displayName)
                                if appearance.theme == theme {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Label("Theme", systemImage: "circle.lefthalf.filled")
                }
                .help("Theme")

                Menu {
                    ForEach(NotesFontOption.allCases) { font in
                        Button {
                            appearance.font = font
                        } label: {
                            HStack {
                                Text(font.displayName)
                                if appearance.font == font {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Smaller") {
                        appearance.fontSize -= 1
                    }
                    Button("Larger") {
                        appearance.fontSize += 1
                    }
                    Text("Size: \(Int(appearance.fontSize))pt")
                } label: {
                    Label("Font", systemImage: "textformat")
                }
                .help("Writing font (Aa)")

                Button {
                    viewModel.lockSelection()
                } label: {
                    Label("Lock", systemImage: "lock.fill")
                }
                .disabled(!viewModel.canLockSelection)
                .help("Lock selected text (copy OK, no edit)")

                Button {
                    viewModel.unlockSelection()
                } label: {
                    Label("Unlock", systemImage: "lock.open.fill")
                }
                .disabled(!viewModel.canUnlockSelection)
                .help("Unlock selection or span at caret")

                Button { attemptNewNote() } label: {
                    Label("New Note", systemImage: "square.and.pencil")
                }
                .help("New note (⌘N)")

                Button { attemptNewTemplate() } label: {
                    Label("New Template", systemImage: "doc.badge.plus")
                }
                .help("New template")

                Menu {
                    if viewModel.templateNotes.isEmpty {
                        Text("No templates yet")
                    } else {
                        ForEach(viewModel.templateNotes) { tmpl in
                            Button(tmpl.displayTitle) {
                                attemptNewFromTemplate(tmpl.id)
                            }
                        }
                    }
                    if viewModel.draftIsTemplate {
                        Divider()
                        Button("Move to Notes") { viewModel.convertTemplateToNote() }
                    } else if viewModel.selectedNoteID != nil {
                        Divider()
                        Button("Move to Templates") { viewModel.saveCurrentAsTemplate() }
                    }
                } label: {
                    Label("From Template", systemImage: "doc.on.doc")
                }
                .help("New note from a template")

                Button {
                    _ = viewModel.fixAllMisspellings()
                } label: {
                    Label("Fix All", systemImage: "text.badge.checkmark")
                }
                .help("Apply top suggestion to every unlocked misspelling (⌥⌘/)")
                .disabled(viewModel.selectedNoteID == nil)

                Button { viewModel.save() } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .disabled(!viewModel.isDirty)
                .help("Save note (⌘S)")
                .keyboardShortcut("s", modifiers: [.command])

                Button { confirmDelete = true } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(viewModel.selectedNoteID == nil)
            }
        }
        .alert("Delete this note?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { viewModel.deleteSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
        .alert("Unsaved changes", isPresented: $showDirtySwitchAlert) {
            Button("Save") {
                viewModel.save()
                if let id = pendingSelection { _ = viewModel.select(id: id, force: true) }
                pendingSelection = nil
            }
            Button("Discard", role: .destructive) {
                if let id = pendingSelection { _ = viewModel.select(id: id, force: true) }
                pendingSelection = nil
            }
            Button("Cancel", role: .cancel) { pendingSelection = nil }
        } message: {
            Text("Save changes before switching notes?")
        }
        .alert("Unsaved changes", isPresented: $showDirtyNewAlert) {
            Button("Save") {
                viewModel.save()
                viewModel.createNote(saveImmediately: true, asTemplate: pendingNewAsTemplate)
                pendingNewAsTemplate = false
            }
            Button("Discard", role: .destructive) {
                // Discard: reload draft from stored note then create.
                if let id = viewModel.selectedNoteID {
                    _ = viewModel.select(id: id, force: true)
                }
                viewModel.createNote(saveImmediately: true, asTemplate: pendingNewAsTemplate)
                pendingNewAsTemplate = false
            }
            Button("Cancel", role: .cancel) {
                pendingNewAsTemplate = false
            }
        } message: {
            Text(pendingNewAsTemplate
                  ? "Save the current note before creating a new template?"
                  : "Save the current note before creating a new one?")
        }
        .alert("Unsaved changes", isPresented: $showDirtyFromTemplateAlert) {
            Button("Save") {
                viewModel.save()
                if let id = pendingTemplateID {
                    _ = viewModel.createNoteFromTemplate(id, force: true)
                }
                pendingTemplateID = nil
            }
            Button("Discard", role: .destructive) {
                if let id = viewModel.selectedNoteID {
                    _ = viewModel.select(id: id, force: true)
                }
                if let tid = pendingTemplateID {
                    _ = viewModel.createNoteFromTemplate(tid, force: true)
                }
                pendingTemplateID = nil
            }
            Button("Cancel", role: .cancel) {
                pendingTemplateID = nil
            }
        } message: {
            Text("Save the current note before creating one from a template?")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { viewModel.selectedNoteID },
                set: { attemptSelect($0) }
            )) {
                Section("Notes") {
                    ForEach(viewModel.regularNotes) { note in
                        noteRow(note)
                    }
                }
                Section("Templates") {
                    ForEach(viewModel.templateNotes) { note in
                        noteRow(note, isTemplate: true)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: colors.sidebarBackground))
            .searchable(text: $viewModel.searchText, prompt: "Search notes")

            if viewModel.regularNotes.isEmpty && viewModel.templateNotes.isEmpty {
                ContentUnavailableView(
                    "No Notes",
                    systemImage: "note.text",
                    description: Text("Create a note or a template to get started.")
                )
                .frame(maxHeight: 160)
            }
        }
        .frame(minWidth: 220)
        .background(Color(nsColor: colors.sidebarBackground))
    }

    @ViewBuilder
    private func noteRow(_ note: Note, isTemplate: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if isTemplate {
                    Image(systemName: "doc.text.fill")
                        .foregroundStyle(Color(nsColor: colors.secondaryText))
                }
                if !note.lockedSpans.isEmpty {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Text(note.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .foregroundStyle(Color(nsColor: colors.editorText))
                if viewModel.selectedNoteID == note.id, viewModel.isDirty {
                    Circle().fill(Color.orange).frame(width: 7, height: 7)
                }
            }
            Text(note.preview)
                .font(.caption)
                .foregroundStyle(Color(nsColor: colors.secondaryText))
                .lineLimit(2)
            Text(note.updatedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(Color(nsColor: colors.secondaryText).opacity(0.85))
        }
        .tag(note.id)
        .listRowBackground(Color(nsColor: colors.sidebarBackground))
        .contextMenu {
            if isTemplate {
                Button("New Note from Template") {
                    attemptNewFromTemplate(note.id)
                }
                Button("Move to Notes") {
                    if viewModel.select(id: note.id, force: true) {
                        viewModel.convertTemplateToNote()
                    }
                }
            } else {
                Button("Move to Templates") {
                    if viewModel.select(id: note.id, force: true) {
                        viewModel.saveCurrentAsTemplate()
                    }
                }
            }
            Button("Delete", role: .destructive) { viewModel.delete(id: note.id) }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if viewModel.selectedNoteID != nil {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    TextField("Title", text: viewModel.titleBinding)
                        .textFieldStyle(.plain)
                        .font(Font(appearance.titleFont()))
                        .foregroundStyle(Color(nsColor: colors.editorText))
                    Spacer()
                    statusChips
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(nsColor: colors.chromeBackground))

                Divider()

                NoteTextEditor(
                    editorBridge: viewModel.editorBridge,
                    text: viewModel.bodyBinding,
                    selectedRange: $viewModel.selectedRange,
                    activeMisspelling: viewModel.activeSuggestion,
                    lockedSpans: viewModel.draftLockedSpans,
                    editorFont: appearance.bodyFont(),
                    textColor: colors.editorText,
                    backgroundColor: colors.editorBackground,
                    onEditingChanged: {
                        viewModel.markDirtyFromEditor()
                    },
                    onWordBoundary: {
                        viewModel.handleWordBoundary()
                    },
                    onCommandNumber: { n in
                        viewModel.applySuggestionShortcut(number: n)
                    },
                    onApplySuggestion: { suggestion, miss in
                        viewModel.applySuggestion(suggestion, for: miss)
                    },
                    onDismissSuggestions: {
                        viewModel.dismissSuggestions()
                    },
                    canEdit: { range, rep in
                        viewModel.canEdit(range: range, replacement: rep)
                    },
                    commitEditorChange: { newText, edited, replacement, preSpans in
                        viewModel.commitEditorChange(
                            newText: newText,
                            edited: edited,
                            replacement: replacement,
                            previousSpans: preSpans
                        )
                    },
                    smartDelete: { range in
                        viewModel.smartDelete(range: range)
                    },
                    currentLockedSpans: {
                        viewModel.draftLockedSpans
                    },
                    onBlockedEdit: {
                        viewModel.notifyBlockedEdit()
                    },
                    restoreSnapshot: { text, spans, sel in
                        viewModel.restoreSnapshot(text: text, spans: spans, selection: sel)
                    }
                )
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
            }
            .background(Color(nsColor: colors.editorBackground))
        } else {
            ContentUnavailableView(
                "Select a Note",
                systemImage: "sidebar.left",
                description: Text("Choose a note from the sidebar or create a new one.")
            )
            .background(Color(nsColor: colors.editorBackground))
        }
    }

    private var statusChips: some View {
        HStack(spacing: 10) {
            if viewModel.isDirty {
                Label("Unsaved", systemImage: "pencil.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if !viewModel.draftLockedSpans.isEmpty {
                Label("\(viewModel.draftLockedSpans.count) locked", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if viewModel.draftIsTemplate {
                Label("Template", systemImage: "doc.text.fill")
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: colors.secondaryText))
            }
            if let active = viewModel.activeSuggestion {
                Label("⌘1–⌘5: \(active.word)", systemImage: "keyboard")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if viewModel.misspellings.isEmpty {
                if !viewModel.draftBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label("Spelling OK", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(Color(nsColor: colors.secondaryText))
                }
            } else {
                Label("\(viewModel.misspellings.count) issue(s)", systemImage: "text.badge.xmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text(viewModel.saveStatus)
                .font(.caption)
                .foregroundStyle(Color(nsColor: colors.secondaryText))
                .lineLimit(1)
        }
    }

    private func attemptSelect(_ id: UUID?) {
        if viewModel.select(id: id) { return }
        pendingSelection = id
        showDirtySwitchAlert = true
    }

    private func attemptNewNote() {
        if viewModel.isDirty {
            pendingNewAsTemplate = false
            showDirtyNewAlert = true
        } else {
            viewModel.createNote(saveImmediately: true, asTemplate: false)
        }
    }

    private func attemptNewTemplate() {
        if viewModel.isDirty {
            pendingNewAsTemplate = true
            showDirtyNewAlert = true
        } else {
            viewModel.createNote(saveImmediately: true, asTemplate: true)
        }
    }

    private func attemptNewFromTemplate(_ id: UUID) {
        if viewModel.isDirty {
            pendingTemplateID = id
            showDirtyFromTemplateAlert = true
        } else {
            _ = viewModel.createNoteFromTemplate(id, force: true)
        }
    }
}
