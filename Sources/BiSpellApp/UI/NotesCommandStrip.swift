import SwiftUI
import AppKit
import BiSpellCore

struct NotesToolbarDivider: View {
    @Environment(\.notesTokens) private var t
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: t.borderSubtle))
            .frame(width: 1, height: 18)
            .padding(.horizontal, 4)
    }
}

struct NotesToolbarChip<LabelContent: View>: View {
    @Environment(\.notesTokens) private var t
    var isPrimary: Bool = false
    var isDestructive: Bool = false
    var disabled: Bool = false
    let action: () -> Void
    @ViewBuilder let label: () -> LabelContent

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(foreground)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(background)
                .overlay(
                    RoundedRectangle(cornerRadius: t.chipRadius, style: .continuous)
                        .strokeBorder(border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: t.chipRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .onHover { hovering = $0 }
    }

    private var foreground: Color {
        if isDestructive { return Color(nsColor: t.danger) }
        if isPrimary { return Color(nsColor: t.accentBright) }
        return Color(nsColor: t.textPrimary)
    }

    private var background: Color {
        if isPrimary {
            return Color(nsColor: hovering ? t.accent : t.accentDim)
        }
        if hovering {
            return Color(nsColor: t.accentDim)
        }
        return Color(nsColor: t.elevated)
    }

    private var border: Color {
        if isPrimary { return Color(nsColor: t.accent) }
        if hovering { return Color(nsColor: t.borderStrong) }
        return Color(nsColor: t.borderSubtle)
    }
}

struct NotesToolbarIconChip: View {
    @Environment(\.notesTokens) private var t
    let systemName: String
    var title: String? = nil
    var isPrimary: Bool = false
    var disabled: Bool = false
    let action: () -> Void
    var helpText: String = ""

    var body: some View {
        NotesToolbarChip(isPrimary: isPrimary, disabled: disabled, action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemName)
                    .font(.system(size: 11, weight: .semibold))
                    .symbolRenderingMode(.monochrome)
                if let title {
                    Text(title)
                }
            }
        }
        .help(helpText)
    }
}

/// Grouped / simplified terminal command strip.
struct NotesCommandStrip: View {
    @Environment(\.notesTokens) private var t
    @ObservedObject var viewModel: NotesViewModel
    @ObservedObject var appearance: NotesAppearanceController

    var onNewNote: () -> Void
    var onNewTemplate: () -> Void
    var onFromTemplate: (UUID) -> Void
    var onDelete: () -> Void
    var onLock: () -> Void
    var onExportJSON: () -> Void
    var onExportMarkdown: () -> Void
    var onImport: () -> Void
    /// External trigger for Regions menu (status bar).
    @Binding var regionsMenuPresented: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                // Create
                NotesToolbarIconChip(
                    systemName: "square.and.pencil",
                    title: "Note",
                    isPrimary: true,
                    action: onNewNote,
                    helpText: "New note (⌘N)"
                )
                createMenu

                NotesToolbarDivider()

                // Write / locks
                locksMenu

                NotesToolbarDivider()

                // View mode
                editorModeMenu

                NotesToolbarDivider()

                // Spelling + save
                NotesToolbarIconChip(
                    systemName: "text.badge.checkmark",
                    title: "Fix All",
                    disabled: viewModel.selectedNoteID == nil,
                    action: { _ = viewModel.fixAllMisspellings() },
                    helpText: "Fix all (⌥⌘/)"
                )
                NotesToolbarIconChip(
                    systemName: "square.and.arrow.down",
                    title: "Save",
                    isPrimary: viewModel.isDirty,
                    disabled: !viewModel.isDirty,
                    action: { viewModel.save() },
                    helpText: "Save (⌘S)"
                )

                NotesToolbarDivider()

                // Look + more
                appearanceMenu
                moreMenu
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: t.chromeBar))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: t.borderSubtle))
                .frame(height: 1)
        }
    }

    private var createMenu: some View {
        Menu {
            Button("Open Today (⌘T)") { viewModel.openToday() }
            Button("New Template") { onNewTemplate() }
            Divider()
            if viewModel.templateNotes.isEmpty {
                Text("No templates yet")
            } else {
                ForEach(viewModel.templateNotes) { tmpl in
                    Button(tmpl.displayTitle) { onFromTemplate(tmpl.id) }
                }
            }
        } label: {
            chipLabel(systemName: "doc.badge.plus", title: "Create")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Today / template / apply template")
    }

    private var locksMenu: some View {
        Menu {
            Button("Lock selection") { onLock() }
                .disabled(!viewModel.canLockSelection)
            Button("Unlock selection") { viewModel.unlockSelection() }
                .disabled(!viewModel.canUnlockSelection)
            Divider()
            if viewModel.draftLockedSpans.isEmpty {
                Text("No locked regions")
            } else {
                ForEach(Array(viewModel.draftLockedSpans.enumerated()), id: \.offset) { index, span in
                    Button("Region \(index + 1)  [\(span.location)+\(span.length)]") {
                        viewModel.jumpToRegion(at: index)
                    }
                }
            }
        } label: {
            chipLabel(systemName: "lock.fill", title: "Regions")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Lock / unlock / jump regions")
        // Status-bar can request opening this menu by flipping binding —
        // we mirror as a popover list when requested.
        .background(regionsPopoverAnchor)
    }

    @ViewBuilder
    private var regionsPopoverAnchor: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .popover(isPresented: $regionsMenuPresented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("REGIONS")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(nsColor: t.textTertiary))
                        .padding(.bottom, 4)
                    if viewModel.draftLockedSpans.isEmpty {
                        Text("No locked regions")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color(nsColor: t.textSecondary))
                    } else {
                        ForEach(Array(viewModel.draftLockedSpans.enumerated()), id: \.offset) { index, span in
                            Button {
                                viewModel.jumpToRegion(at: index)
                                regionsMenuPresented = false
                            } label: {
                                HStack {
                                    Image(systemName: "lock.fill")
                                    Text("Region \(index + 1)")
                                    Spacer()
                                    Text("\(span.location)+\(span.length)")
                                        .foregroundStyle(Color(nsColor: t.textTertiary))
                                }
                                .font(.system(size: 12, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 3)
                        }
                    }
                }
                .padding(12)
                .frame(minWidth: 220)
                .background(Color(nsColor: t.chromeBar))
            }
    }

    private var editorModeMenu: some View {
        Menu {
            ForEach(NoteEditorMode.allCases) { mode in
                Button {
                    viewModel.editorMode = mode
                } label: {
                    HStack {
                        Image(systemName: mode.systemImage)
                        Text(mode.label)
                        if viewModel.editorMode == mode {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            Divider()
            Button("Cycle Source → Split → Preview") {
                viewModel.cycleEditorMode()
            }
        } label: {
            chipLabel(systemName: viewModel.editorMode.systemImage, title: viewModel.editorMode.label)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Markdown source / split / preview")
    }

    private var appearanceMenu: some View {
        Menu {
            Section("Theme") {
                ForEach(NotesTheme.allCases) { theme in
                    Button {
                        appearance.theme = theme
                    } label: {
                        HStack {
                            Circle()
                                .fill(Color(nsColor: theme.tokens().accent))
                                .frame(width: 8, height: 8)
                            Text(theme.displayName)
                            if appearance.theme == theme {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            Section("Font") {
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
                Button("Smaller") { appearance.fontSize -= 1 }
                Button("Larger") { appearance.fontSize += 1 }
            }
            Section("Text color") {
                ForEach(NotesTextColorOption.allCases) { opt in
                    Button {
                        appearance.textColor = opt
                    } label: {
                        Text(opt.displayName)
                    }
                }
            }
        } label: {
            chipLabel(systemName: "paintpalette", title: "Look")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Theme, font, text color")
    }

    private var moreMenu: some View {
        Menu {
            if viewModel.draftIsTemplate {
                Button("Move to Notes") { viewModel.convertTemplateToNote() }
            } else if viewModel.selectedNoteID != nil {
                Button("Move to Templates") { viewModel.saveCurrentAsTemplate() }
            }
            Button("Reveal in Finder") { viewModel.revealSelectedInFinder() }
                .disabled(viewModel.selectedNoteID == nil)
            Button("Quick Switcher… (⌘P)") { viewModel.openQuickSwitcher() }
            Divider()
            Section("Sort") {
                ForEach(NoteSortMode.allCases) { mode in
                    Button {
                        viewModel.sortMode = mode
                    } label: {
                        HStack {
                            Text(mode.label)
                            if viewModel.sortMode == mode { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
            Divider()
            Button("Export templates as JSON…") { onExportJSON() }
            Button("Export templates as Markdown…") { onExportMarkdown() }
            Button("Import files…") { onImport() }
            Button("Import Markdown folder…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.prompt = "Import Folder"
                panel.message = "Import all .md files into the library (default: archive)"
                panel.begin { resp in
                    guard resp == .OK, let url = panel.url else { return }
                    DispatchQueue.main.async {
                        _ = viewModel.importMarkdownDirectory(url, destFolder: LibraryPaths.archive)
                    }
                }
            }
            Button("Backup Library…") { _ = viewModel.backupLibrary() }
            if viewModel.trashCount > 0 {
                Button("Empty Trash (\(viewModel.trashCount))") { viewModel.emptyTrash() }
            }
            Divider()
            Button("Move to Trash", role: .destructive, action: onDelete)
                .disabled(viewModel.selectedNoteID == nil)
        } label: {
            chipLabel(systemName: "ellipsis", title: "More")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func chipLabel(systemName: String, title: String?) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .symbolRenderingMode(.monochrome)
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .opacity(0.6)
        }
        .foregroundStyle(Color(nsColor: t.textPrimary))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: t.elevated))
        .overlay(
            RoundedRectangle(cornerRadius: t.chipRadius, style: .continuous)
                .strokeBorder(Color(nsColor: t.borderSubtle), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: t.chipRadius, style: .continuous))
    }
}
