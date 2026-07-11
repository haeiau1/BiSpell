import SwiftUI
import AppKit
import UniformTypeIdentifiers
import BiSpellCore

struct NotesRootView: View {
    @ObservedObject var viewModel: NotesViewModel
    @ObservedObject var appearance: NotesAppearanceController
    @StateObject private var taxonomy = TaxonomyController()
    @Environment(\.colorScheme) private var colorScheme

    @State private var confirmDelete = false
    @State private var pendingSelection: UUID?
    @State private var showDirtySwitchAlert = false
    @State private var showDirtyNewAlert = false
    @State private var pendingNewAsTemplate = false
    @State private var pendingTemplateID: UUID?
    @State private var showDirtyFromTemplateAlert = false

    @State private var exportJSONData: Data?
    @State private var showExportJSON = false
    @State private var exportMarkdownFiles: [(String, String)] = []
    @State private var showExportMarkdown = false
    @State private var regionsMenuPresented = false
    @State private var foldersExpanded = true
    @State private var tagsExpanded = true
    @State private var showRenameFolder = false
    @State private var renameFolderFrom: String = ""
    @State private var renameFolderTo: String = ""
    @State private var showDeleteFolder = false
    @State private var deleteFolderName: String = ""
    @State private var showRenameTag = false
    @State private var renameTagFrom: String = ""
    @State private var renameTagTo: String = ""
    @State private var showDeleteTag = false
    @State private var deleteTagName: String = ""

    private var tokens: NotesThemeTokens {
        appearance.tokens(colorScheme: colorScheme)
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationTitle("BiSpell Notes")
        .toolbarBackground(Color(nsColor: tokens.chromeBar), for: .windowToolbar)
        .environment(\.notesTokens, tokens)
        .background(Color(nsColor: tokens.window))
        .alert("Move note to trash?", isPresented: $confirmDelete) {
            Button("Move to Trash", role: .destructive) { viewModel.deleteSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The note moves to .bispell/trash/ under your library. Empty trash from Settings or More.")
        }
        .alert("Unsaved changes", isPresented: $showDirtySwitchAlert) {
            Button("Save") {
                // Abort navigation if save fails so the dirty draft is not wiped.
                guard viewModel.flushPendingSave() else { return }
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
                guard viewModel.flushPendingSave() else { return }
                viewModel.createNote(saveImmediately: true, asTemplate: pendingNewAsTemplate)
                pendingNewAsTemplate = false
            }
            Button("Discard", role: .destructive) {
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
                guard viewModel.flushPendingSave() else { return }
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
            Text("Save the current note before applying a template?")
        }
        .sheet(item: $viewModel.pendingVariableForm) { form in
            TemplateVariablesSheet(
                keys: form.keys,
                initial: form.values,
                onSubmit: { values in
                    viewModel.submitVariableForm(values: values)
                },
                onCancel: { viewModel.cancelVariableForm() }
            )
            .environment(\.notesTokens, tokens)
        }
        .sheet(isPresented: $viewModel.showQuickSwitcher) {
            QuickSwitcherView(viewModel: viewModel)
                .environment(\.notesTokens, tokens)
        }
        .alert("Rename folder", isPresented: $showRenameFolder) {
            TextField("New path", text: $renameFolderTo)
            Button("Rename") {
                viewModel.renameFolder(from: renameFolderFrom, to: renameFolderTo)
                taxonomy.renameFolderColor(from: renameFolderFrom, to: renameFolderTo)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Rename “\(renameFolderFrom)” on disk (and nested notes).")
        }
        .alert("Delete folder?", isPresented: $showDeleteFolder) {
            Button("Move notes to inbox", role: .destructive) {
                _ = viewModel.deleteFolder(deleteFolderName)
                taxonomy.removeFolderColor(deleteFolderName)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Notes under “\(deleteFolderName)” move to inbox/. The folder is removed.")
        }
        .alert("Rename tag", isPresented: $showRenameTag) {
            TextField("New tag name", text: $renameTagTo)
            Button("Rename") {
                _ = viewModel.renameTag(from: renameTagFrom, to: renameTagTo)
                taxonomy.renameTagColor(from: renameTagFrom, to: renameTagTo)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Rename “\(renameTagFrom)” on every note that uses it.")
        }
        .alert("Delete tag?", isPresented: $showDeleteTag) {
            Button("Remove from all notes", role: .destructive) {
                _ = viewModel.deleteTag(deleteTagName)
                taxonomy.removeTagColor(deleteTagName)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Remove “\(deleteTagName)” from all notes. Notes themselves are kept.")
        }
        .fileExporter(
            isPresented: $showExportJSON,
            document: JSONFileDocument(data: exportJSONData ?? Data()),
            contentType: .json,
            defaultFilename: "bispell-templates"
        ) { _ in }
    }

    /// Collapsible folder + tag filter sections (top of sidebar).
    private var filterChips: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Folders section
            filterSectionHeader(
                title: "folders",
                count: viewModel.allFolders.count,
                expanded: $foldersExpanded,
                active: viewModel.selectedFolderFilter != nil
            ) {
                viewModel.selectedFolderFilter = nil
            }
            if foldersExpanded {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        TaxonomyChip(
                            title: "all",
                            palette: .slate,
                            selected: viewModel.selectedFolderFilter == nil,
                            showDot: false
                        ) {
                            viewModel.selectedFolderFilter = nil
                        }
                        ForEach(viewModel.allFolders, id: \.self) { folder in
                            TaxonomyChip(
                                title: folder,
                                palette: taxonomy.folderPalette(folder),
                                selected: viewModel.selectedFolderFilter == folder,
                                action: {
                                    viewModel.selectedFolderFilter =
                                        viewModel.selectedFolderFilter == folder ? nil : folder
                                },
                                onColorPick: { taxonomy.setFolderColor($0, for: folder) },
                                contextMenuExtra: {
                                    Button("Rename folder…") {
                                        renameFolderFrom = folder
                                        renameFolderTo = folder
                                        showRenameFolder = true
                                    }
                                    if folder != "inbox" {
                                        Button("Delete folder…", role: .destructive) {
                                            deleteFolderName = folder
                                            showDeleteFolder = true
                                        }
                                    }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                }
            }

            Rectangle().fill(Color(nsColor: tokens.borderSubtle)).frame(height: 1)

            // Tags section
            filterSectionHeader(
                title: "tags",
                count: viewModel.allTags.count,
                expanded: $tagsExpanded,
                active: !viewModel.selectedTagFilters.isEmpty
            ) {
                viewModel.clearTagFilters()
            }
            if tagsExpanded {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if !viewModel.selectedTagFilters.isEmpty {
                            TaxonomyChip(
                                title: "clear",
                                palette: .slate,
                                selected: false,
                                showDot: false
                            ) {
                                viewModel.clearTagFilters()
                            }
                        }
                        ForEach(viewModel.allTags, id: \.self) { tag in
                            TaxonomyChip(
                                title: tag,
                                palette: taxonomy.tagPalette(tag),
                                selected: viewModel.selectedTagFilters.contains(tag),
                                action: { viewModel.toggleTagFilter(tag) },
                                onColorPick: { taxonomy.setTagColor($0, for: tag) },
                                contextMenuExtra: {
                                    Button("Rename tag…") {
                                        renameTagFrom = tag
                                        renameTagTo = tag
                                        showRenameTag = true
                                    }
                                    Button("Delete tag…", role: .destructive) {
                                        deleteTagName = tag
                                        showDeleteTag = true
                                    }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                }
            }
        }
        .background(Color(nsColor: tokens.sidebar))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(nsColor: tokens.borderSubtle)).frame(height: 1)
        }
    }

    private func filterSectionHeader(
        title: String,
        count: Int,
        expanded: Binding<Bool>,
        active: Bool,
        onClear: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    expanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color(nsColor: tokens.textTertiary))
                        .frame(width: 10)
                    Text(title.uppercased())
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1.0)
                        .foregroundStyle(Color(nsColor: active ? tokens.accentBright : tokens.textSecondary))
                    Text("\(count)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Color(nsColor: tokens.textTertiary))
                }
            }
            .buttonStyle(.plain)
            Spacer()
            if active {
                Button("clear", action: onClear)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color(nsColor: tokens.accent))
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func exportJSON() {
        do {
            exportJSONData = try viewModel.exportTemplatesJSON()
            showExportJSON = true
        } catch {
            viewModel.saveStatus = "Export failed"
        }
    }

    private func exportMarkdown() {
        let files = viewModel.exportTemplatesMarkdown()
        guard !files.isEmpty else {
            viewModel.saveStatus = "No templates to export"
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.begin { resp in
            guard resp == .OK, let dir = panel.url else { return }
            do {
                for (name, contents) in files {
                    let url = dir.appendingPathComponent(name)
                    try contents.write(to: url, atomically: true, encoding: .utf8)
                }
                DispatchQueue.main.async {
                    viewModel.saveStatus = "Exported \(files.count) markdown file(s)"
                }
            } catch {
                DispatchQueue.main.async {
                    viewModel.saveStatus = "Markdown export failed"
                }
            }
        }
    }

    /// Use AppKit open panel — SwiftUI `.fileImporter` often fails to present when
    /// triggered from a toolbar `Menu` (state tears down with the menu).
    private func openImportPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        panel.message = "Choose BiSpell template pack (.json) or template markdown (.md)"
        var types: [UTType] = [.json, .plainText, .text, .data]
        if let md = UTType(filenameExtension: "md") { types.append(md) }
        if let markdown = UTType(filenameExtension: "markdown") { types.append(markdown) }
        if let yaml = UTType(filenameExtension: "yaml") { types.append(yaml) }
        panel.allowedContentTypes = types
        panel.allowsOtherFileTypes = true
        panel.begin { resp in
            guard resp == .OK else {
                DispatchQueue.main.async {
                    viewModel.saveStatus = "Import cancelled"
                }
                return
            }
            let urls = panel.urls
            DispatchQueue.main.async {
                importTemplateFiles(urls)
            }
        }
    }

    private func importTemplateFiles(_ urls: [URL]) {
        viewModel.saveStatus = "Importing \(urls.count) file(s)…"
        // Read + parse off the main thread; commit once (avoids per-file spell-check stalls).
        Task.detached(priority: .userInitiated) {
            var parsed: [Note] = []
            var errors: [String] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    let notes = try NotesViewModel.parseImportFile(
                        data: data,
                        pathExtension: url.pathExtension
                    )
                    parsed.append(contentsOf: notes)
                } catch {
                    errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            let imported = parsed
            let importErrors = errors
            let largeBodies = imported.contains { ($0.body as NSString).length > 4_000 }
            await MainActor.run {
                do {
                    let count = try viewModel.commitImportedNotes(imported, selectFirst: true)
                    viewModel.selectedFolderFilter = nil
                    viewModel.clearTagFilters()
                    // Prefer split so large MD imports feel instant and show end product.
                    if count > 0, largeBodies {
                        viewModel.editorMode = .split
                    }
                    if count == 0, !importErrors.isEmpty {
                        viewModel.saveStatus = "Import failed: \(importErrors.joined(separator: "; "))"
                    } else if count > 0, !importErrors.isEmpty {
                        viewModel.saveStatus += " · some failed: \(importErrors.joined(separator: "; "))"
                    } else if count == 0 {
                        viewModel.saveStatus = "No notes found in selected file(s)"
                    }
                } catch {
                    viewModel.saveStatus = "Import failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            // Terminal header
            HStack(spacing: 6) {
                Text("biSpell")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(nsColor: tokens.accent))
                Text("// notes")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(nsColor: tokens.textTertiary))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(nsColor: tokens.sidebar))
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color(nsColor: tokens.borderSubtle)).frame(height: 1)
            }

            // Filters first (collapsible folders + tags)
            if !viewModel.allFolders.isEmpty || !viewModel.allTags.isEmpty {
                filterChips
            }

            // Shortcuts
            HStack(spacing: 8) {
                Button {
                    viewModel.openToday()
                } label: {
                    Label("Today", systemImage: "sun.max")
                        .font(.system(size: 11, design: .monospaced))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(nsColor: tokens.accent))
                Button {
                    viewModel.selectedFolderFilter = LibraryPaths.inbox
                    viewModel.clearTagFilters()
                } label: {
                    Label("Inbox", systemImage: "tray")
                        .font(.system(size: 11, design: .monospaced))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(nsColor: tokens.textSecondary))
                Spacer()
                Menu {
                    ForEach(NoteSortMode.allCases) { mode in
                        Button(mode.label) { viewModel.sortMode = mode }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: tokens.textTertiary))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: tokens.sidebar))

            List(selection: Binding(
                get: { viewModel.selectedNoteID },
                set: { attemptSelect($0) }
            )) {
                Section {
                    ForEach(viewModel.regularNotes) { note in
                        NotesSidebarRow(
                            note: note,
                            isTemplate: false,
                            isSelected: viewModel.selectedNoteID == note.id,
                            isDirty: viewModel.selectedNoteID == note.id && viewModel.isDirty,
                            taxonomy: taxonomy
                        )
                        .tag(note.id)
                        .listRowBackground(Color(nsColor: tokens.sidebar))
                        .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                        .contextMenu { noteContextMenu(note, isTemplate: false) }
                    }
                } header: {
                    NotesSectionHeader(title: "Notes")
                }

                Section {
                    ForEach(viewModel.templateNotes) { note in
                        NotesSidebarRow(
                            note: note,
                            isTemplate: true,
                            isSelected: viewModel.selectedNoteID == note.id,
                            isDirty: viewModel.selectedNoteID == note.id && viewModel.isDirty,
                            taxonomy: taxonomy
                        )
                        .tag(note.id)
                        .listRowBackground(Color(nsColor: tokens.sidebar))
                        .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                        .contextMenu { noteContextMenu(note, isTemplate: true) }
                    }
                } header: {
                    NotesSectionHeader(title: "Templates")
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: tokens.sidebar))
            .searchable(text: $viewModel.searchText, prompt: "search…")

            if viewModel.regularNotes.isEmpty && viewModel.templateNotes.isEmpty {
                Text("// empty — create a note")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(nsColor: tokens.textTertiary))
                    .frame(maxWidth: .infinity)
                    .padding()
            }
        }
        .frame(minWidth: 220)
        .background(Color(nsColor: tokens.sidebar))
    }

    @ViewBuilder
    private func noteContextMenu(_ note: Note, isTemplate: Bool) -> some View {
        if isTemplate {
            Button("Apply Template") {
                attemptNewFromTemplate(note.id)
            }
            Button("Move to Notes") {
                // Flush first so force-select cannot discard another note's dirty draft.
                guard viewModel.flushPendingSave() else { return }
                if viewModel.select(id: note.id, force: true) {
                    viewModel.convertTemplateToNote()
                }
            }
        } else {
            Button("Move to Templates") {
                guard viewModel.flushPendingSave() else { return }
                if viewModel.select(id: note.id, force: true) {
                    viewModel.saveCurrentAsTemplate()
                }
            }
        }
        if let folder = note.folder {
            Button("Filter folder “\(folder)”") {
                viewModel.selectedFolderFilter = folder
            }
            Button("Rename folder…") {
                renameFolderFrom = folder
                renameFolderTo = folder
                showRenameFolder = true
            }
            if folder != "inbox" {
                Button("Delete folder…", role: .destructive) {
                    deleteFolderName = folder
                    showDeleteFolder = true
                }
            }
        }
        if viewModel.isNoteSplit {
            Button("Open in Right Pane") {
                viewModel.openInSplit(note.id)
            }
        } else {
            Button("Open in Split") {
                viewModel.openInSplit(note.id)
            }
        }
        Button("Reveal in Finder") {
            guard viewModel.flushPendingSave() else { return }
            if viewModel.select(id: note.id, force: true) {
                viewModel.revealSelectedInFinder()
            }
        }
        Button("Move to Trash", role: .destructive) { viewModel.delete(id: note.id) }
    }

    @ViewBuilder
    private func editorWorkspace(isSecondary: Bool) -> some View {
        let mode = isSecondary ? viewModel.secondaryEditorMode : viewModel.editorMode
        let body = isSecondary ? viewModel.secondaryDraftBody : viewModel.draftBody
        let source = noteSourceEditor(isSecondary: isSecondary)
        let preview = MarkdownPreviewView(
            markdown: body,
            tokens: tokens,
            pointSize: appearance.bodyFont().pointSize
        )
        // Per-pane markdown mode (Source / MD-Split / Preview) — independent of note split.
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(NoteEditorMode.allCases) { m in
                    Button {
                        if isSecondary {
                            viewModel.secondaryEditorMode = m
                            viewModel.focusPane(.secondary)
                        } else {
                            viewModel.editorMode = m
                            viewModel.focusPane(.primary)
                        }
                    } label: {
                        Image(systemName: m.systemImage)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color(nsColor: mode == m ? tokens.accentBright : tokens.textTertiary))
                            .padding(4)
                    }
                    .buttonStyle(.plain)
                    .help(m.label)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)

            Group {
                switch mode {
                case .source:
                    source
                case .preview:
                    preview
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color(nsColor: tokens.borderSubtle), lineWidth: 1)
                        )
                case .split:
                    HSplitView {
                        source
                            .frame(minWidth: 160)
                        preview
                            .frame(minWidth: 160)
                    }
                }
            }
        }
    }

    private func noteSourceEditor(isSecondary: Bool) -> some View {
        Group {
            if isSecondary {
                NoteTextEditor(
                    editorBridge: viewModel.secondaryEditorBridge,
                    text: viewModel.secondaryBodyBinding,
                    selectedRange: $viewModel.secondarySelectedRange,
                    activeMisspelling: viewModel.secondaryActiveSuggestion,
                    lockedSpans: viewModel.secondaryDraftLockedSpans,
                    editorFont: appearance.bodyFont(),
                    textColor: tokens.textPrimary,
                    backgroundColor: tokens.editor,
                    lockedBackgroundColor: tokens.lockFill,
                    lockedTextColor: tokens.lockText,
                    accentColor: tokens.accent,
                    borderColor: tokens.borderStrong,
                    onEditingChanged: {
                        viewModel.focusPane(.secondary)
                        viewModel.markSecondaryDirtyFromEditor()
                    },
                    onWordBoundary: {
                        viewModel.focusPane(.secondary)
                        viewModel.handleWordBoundary()
                    },
                    onCommandNumber: { n in
                        viewModel.focusPane(.secondary)
                        viewModel.applySuggestionShortcut(number: n)
                    },
                    onApplySuggestion: { suggestion, miss in
                        viewModel.focusPane(.secondary)
                        viewModel.applySuggestion(suggestion, for: miss)
                    },
                    onDismissSuggestions: {
                        viewModel.dismissSecondarySuggestions()
                    },
                    canEdit: { range, rep in
                        viewModel.canEditSecondary(range: range, replacement: rep)
                    },
                    commitEditorChange: { newText, edited, replacement, preSpans in
                        viewModel.focusPane(.secondary)
                        viewModel.commitSecondaryEditorChange(
                            newText: newText,
                            edited: edited,
                            replacement: replacement,
                            previousSpans: preSpans
                        )
                    },
                    smartDelete: { range in
                        viewModel.focusPane(.secondary)
                        viewModel.smartDeleteSecondary(range: range)
                    },
                    currentLockedSpans: {
                        viewModel.secondaryDraftLockedSpans
                    },
                    onBlockedEdit: {
                        viewModel.notifyBlockedEdit()
                    },
                    restoreSnapshot: { text, spans, sel in
                        viewModel.restoreSecondarySnapshot(text: text, spans: spans, selection: sel)
                    }
                )
            } else {
                NoteTextEditor(
                    editorBridge: viewModel.editorBridge,
                    text: viewModel.bodyBinding,
                    selectedRange: $viewModel.selectedRange,
                    activeMisspelling: viewModel.activeSuggestion,
                    lockedSpans: viewModel.draftLockedSpans,
                    editorFont: appearance.bodyFont(),
                    textColor: tokens.textPrimary,
                    backgroundColor: tokens.editor,
                    lockedBackgroundColor: tokens.lockFill,
                    lockedTextColor: tokens.lockText,
                    accentColor: tokens.accent,
                    borderColor: tokens.borderStrong,
                    onEditingChanged: {
                        viewModel.focusPane(.primary)
                        viewModel.markDirtyFromEditor()
                    },
                    onWordBoundary: {
                        viewModel.focusPane(.primary)
                        viewModel.handleWordBoundary()
                    },
                    onCommandNumber: { n in
                        viewModel.focusPane(.primary)
                        viewModel.applySuggestionShortcut(number: n)
                    },
                    onApplySuggestion: { suggestion, miss in
                        viewModel.focusPane(.primary)
                        viewModel.applySuggestion(suggestion, for: miss)
                    },
                    onDismissSuggestions: {
                        viewModel.dismissSuggestions()
                    },
                    canEdit: { range, rep in
                        viewModel.canEdit(range: range, replacement: rep)
                    },
                    commitEditorChange: { newText, edited, replacement, preSpans in
                        viewModel.focusPane(.primary)
                        viewModel.commitEditorChange(
                            newText: newText,
                            edited: edited,
                            replacement: replacement,
                            previousSpans: preSpans
                        )
                    },
                    smartDelete: { range in
                        viewModel.focusPane(.primary)
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
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if viewModel.selectedNoteID != nil || viewModel.secondaryNoteID != nil {
            VStack(spacing: 0) {
                NotesCommandStrip(
                    viewModel: viewModel,
                    appearance: appearance,
                    onNewNote: attemptNewNote,
                    onNewTemplate: attemptNewTemplate,
                    onFromTemplate: attemptNewFromTemplate,
                    onDelete: { confirmDelete = true },
                    onLock: { viewModel.lockSelection() },
                    onExportJSON: exportJSON,
                    onExportMarkdown: exportMarkdown,
                    onImport: openImportPanel,
                    regionsMenuPresented: $regionsMenuPresented
                )

                if !viewModel.openTabIDs.isEmpty {
                    NotesTabBar(viewModel: viewModel)
                }

                if viewModel.isNoteSplit {
                    HSplitView {
                        notePane(isSecondary: false)
                            .frame(minWidth: 280)
                        notePane(isSecondary: true)
                            .frame(minWidth: 280)
                    }
                } else {
                    notePane(isSecondary: false)
                }

                NotesStatusBar(
                    viewModel: viewModel,
                    appearance: appearance,
                    onOpenRegions: { regionsMenuPresented = true }
                )
            }
            .background(Color(nsColor: tokens.editor))
        } else {
            VStack(spacing: 12) {
                Text(">")
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(nsColor: tokens.accent))
                Text("select a note or create one")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color(nsColor: tokens.textSecondary))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: tokens.editor))
        }
    }

    /// One note column: metadata + markdown Source/Split/Preview editor.
    @ViewBuilder
    private func notePane(isSecondary: Bool) -> some View {
        let focused = isSecondary
            ? (viewModel.focusedPane == .secondary)
            : (viewModel.focusedPane == .primary || !viewModel.isNoteSplit)
        let hasNote = isSecondary ? viewModel.secondaryNoteID != nil : viewModel.selectedNoteID != nil

        VStack(spacing: 0) {
            if viewModel.isNoteSplit {
                HStack(spacing: 8) {
                    Text(isSecondary ? "right" : "left")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(nsColor: focused ? tokens.accentBright : tokens.textTertiary))
                    Spacer()
                    if isSecondary {
                        Button("Close split") {
                            viewModel.closeNoteSplit()
                        }
                        .font(.system(size: 10, design: .monospaced))
                        .buttonStyle(.plain)
                        .foregroundStyle(Color(nsColor: tokens.textSecondary))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color(nsColor: focused ? tokens.accentDim : tokens.chromeBar))
                .contentShape(Rectangle())
                .onTapGesture {
                    viewModel.focusPane(isSecondary ? .secondary : .primary)
                }
            }

            if hasNote {
                noteChrome(isSecondary: isSecondary)
                editorWorkspace(isSecondary: isSecondary)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 2)
                    .onTapGesture {
                        viewModel.focusPane(isSecondary ? .secondary : .primary)
                    }
            } else {
                VStack(spacing: 8) {
                    Text(isSecondary ? "pick a note for the right pane" : "select a note")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color(nsColor: tokens.textSecondary))
                    Text("use sidebar or Open in Split")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color(nsColor: tokens.textTertiary))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: tokens.editor))
                .onTapGesture {
                    viewModel.focusPane(isSecondary ? .secondary : .primary)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .strokeBorder(
                    focused && viewModel.isNoteSplit
                        ? Color(nsColor: tokens.accent).opacity(0.45)
                        : Color.clear,
                    lineWidth: 1
                )
        )
    }

    @ViewBuilder
    private func noteChrome(isSecondary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("›")
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(nsColor: tokens.accent))
                if isSecondary {
                    TextField("untitled", text: viewModel.secondaryTitleBinding)
                        .textFieldStyle(.plain)
                        .font(Font(appearance.titleFont()))
                        .foregroundStyle(Color(nsColor: tokens.textPrimary))
                        .onTapGesture { viewModel.focusPane(.secondary) }
                } else {
                    TextField("untitled", text: viewModel.titleBinding)
                        .textFieldStyle(.plain)
                        .font(Font(appearance.titleFont()))
                        .foregroundStyle(Color(nsColor: tokens.textPrimary))
                        .onTapGesture { viewModel.focusPane(.primary) }
                }
                Spacer()
            }
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("folder")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color(nsColor: tokens.textTertiary))
                    if isSecondary {
                        FolderPickerField(
                            folder: Binding(
                                get: { viewModel.secondaryDraftFolder },
                                set: { viewModel.setSecondaryFolder($0) }
                            ),
                            knownFolders: viewModel.allFolders,
                            taxonomy: taxonomy
                        )
                        .frame(minWidth: 120, maxWidth: 180)
                    } else {
                        FolderPickerField(
                            folder: Binding(
                                get: { viewModel.draftFolder },
                                set: { viewModel.setFolder($0) }
                            ),
                            knownFolders: viewModel.allFolders,
                            taxonomy: taxonomy
                        )
                        .frame(minWidth: 120, maxWidth: 180)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("tags")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color(nsColor: tokens.textTertiary))
                    if isSecondary {
                        TagsPickerField(
                            tagsText: Binding(
                                get: { viewModel.secondaryDraftTagsText },
                                set: { viewModel.setSecondaryTagsText($0) }
                            ),
                            knownTags: viewModel.allTags,
                            taxonomy: taxonomy
                        )
                    } else {
                        TagsPickerField(
                            tagsText: Binding(
                                get: { viewModel.draftTagsText },
                                set: { viewModel.setTagsText($0) }
                            ),
                            knownTags: viewModel.allTags,
                            taxonomy: taxonomy
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: tokens.chromeBar))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(nsColor: tokens.borderSubtle)).frame(height: 1)
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


// MARK: - Quick switcher (⌘P)

struct QuickSwitcherView: View {
    @ObservedObject var viewModel: NotesViewModel
    @Environment(\.notesTokens) private var tokens
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color(nsColor: tokens.textTertiary))
                TextField("Jump to note…", text: $viewModel.quickSwitcherQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, design: .monospaced))
                    .focused($focused)
                    .onSubmit { selectFirst() }
                Button("Esc") {
                    viewModel.closeQuickSwitcher()
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(nsColor: tokens.textTertiary))
            }
            .padding(12)
            .background(Color(nsColor: tokens.chromeBar))

            List(viewModel.quickSwitcherResults()) { note in
                Button {
                    viewModel.selectFromQuickSwitcher(note.id)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.displayTitle)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color(nsColor: tokens.textPrimary))
                        Text(viewModel.relativePath(for: note.id) ?? note.folder ?? "")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color(nsColor: tokens.textTertiary))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(Color(nsColor: tokens.sidebar))
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: tokens.editor))
        }
        .frame(width: 480, height: 360)
        .background(Color(nsColor: tokens.window))
        .onAppear { focused = true }
    }

    private func selectFirst() {
        if let first = viewModel.quickSwitcherResults().first {
            viewModel.selectFromQuickSwitcher(first.id)
            dismiss()
        }
    }
}
