import SwiftUI
import AppKit
import Combine
import BiSpellCore

@main
struct BiSpellApp: App {
    @NSApplicationDelegateAdaptor(AppModel.self) private var appModel

    var body: some Scene {
        WindowGroup("BiSpell Notes", id: "notes") {
            NotesRootView(viewModel: appModel.notesViewModel, appearance: appModel.notesAppearance)
                .frame(minWidth: 720, minHeight: 440)
                .focusedSceneValue(\.notesViewModel, appModel.notesViewModel)
        }
        .defaultSize(width: 960, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note") {
                    if appModel.notesViewModel.isDirty {
                        appModel.notesViewModel.save()
                    }
                    appModel.notesViewModel.createNote(saveImmediately: true)
                    appModel.showNotesWindow()
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Note") {
                    appModel.notesViewModel.save()
                }
                .keyboardShortcut("s", modifiers: [.command])
            }
            CommandMenu("Spelling") {
                Button("Show Suggestions at Caret") {
                    appModel.handleSuggestionHotkey()
                }
                .keyboardShortcut(".", modifiers: [.command, .option])
                Button("Fix All (Top Suggestions)") {
                    appModel.handleFixAllHotkey()
                }
                .keyboardShortcut("/", modifiers: [.command, .option])
                Button("Accept Suggestion 1 (best)") { appModel.notesViewModel.applySuggestionShortcut(number: 1) }
                    .keyboardShortcut("1", modifiers: [.command])
                Button("Accept Suggestion 2") { appModel.notesViewModel.applySuggestionShortcut(number: 2) }
                    .keyboardShortcut("2", modifiers: [.command])
                Button("Accept Suggestion 3") { appModel.notesViewModel.applySuggestionShortcut(number: 3) }
                    .keyboardShortcut("3", modifiers: [.command])
                Button("Accept Suggestion 4") { appModel.notesViewModel.applySuggestionShortcut(number: 4) }
                    .keyboardShortcut("4", modifiers: [.command])
                Button("Accept Suggestion 5") { appModel.notesViewModel.applySuggestionShortcut(number: 5) }
                    .keyboardShortcut("5", modifiers: [.command])
            }
        }

        MenuBarExtra {
            MenuContent(appModel: appModel)
        } label: {
            Image(systemName: appModel.iconName)
        }

        Settings {
            SettingsView(session: appModel.session)
        }
    }
}

private struct MenuContent: View {
    @ObservedObject var appModel: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let session = appModel.session

        Button("Open Notes") {
            openWindow(id: "notes")
            appModel.showNotesWindow()
        }
        Divider()
        Button(session.settings.isEnabled ? "Disable Checking" : "Enable Checking") {
            session.toggleEnabled()
        }
        Toggle("Paused", isOn: Binding(
            get: { session.isPaused },
            set: { session.isPaused = $0 }
        ))
        Divider()
        Button("Check Now / Show Suggestion  (⌥⌘.)") {
            appModel.handleSuggestionHotkey()
        }
        Button("Fix All Top Suggestions  (⌥⌘/)") {
            appModel.handleFixAllHotkey()
        }
        Button("Probe Frontmost App Support") {
            session.probeSupport()
        }
        Divider()
        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        Divider()
        if !session.accessibilityGranted {
            Button("Grant Accessibility…") {
                session.requestAccessibility()
                session.openAccessibilitySettings()
            }
        }
        Button("Quit BiSpell") {
            appModel.notesViewModel.flushPendingSave()
            NSApplication.shared.terminate(nil)
        }
    }
}

@MainActor
final class AppModel: NSObject, NSApplicationDelegate, ObservableObject {
    let session = SpellSessionController()
    private(set) lazy var notesViewModel: NotesViewModel = {
        NotesViewModel(store: NotesStore(), engine: session.engine)
    }()
    let notesAppearance = NotesAppearanceController()
    private let hotkeys = HotkeyManager()
    private var didBootstrap = false
    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()
        session.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        bootstrap()
        DispatchQueue.main.async { [weak self] in
            self?.showNotesWindow()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showNotesWindow()
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if notesViewModel.isDirty {
            let alert = NSAlert()
            alert.messageText = "Save notes before quitting?"
            alert.informativeText = "You have unsaved changes in BiSpell Notes."
            alert.addButton(withTitle: "Save and Quit")
            alert.addButton(withTitle: "Quit Without Saving")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                notesViewModel.save()
                return .terminateNow
            case .alertSecondButtonReturn:
                return .terminateNow
            default:
                return .terminateCancel
            }
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        session.stop()
    }

    var iconName: String {
        if !session.accessibilityGranted { return "character.textbox" }
        if session.isPaused || !session.settings.isEnabled { return "pause.circle" }
        if session.misspellingCount > 0 { return "text.badge.xmark" }
        return "checkmark.circle"
    }

    /// Route ⌥⌘. to notes when the notes window is key; otherwise system-wide AX flow.
    func handleSuggestionHotkey() {
        if isNotesWindowKey {
            notesViewModel.handleSuggestionHotkey()
        } else {
            session.hotkeyCheckSelectionOrFirstMistake()
        }
    }

    /// Route ⌥⌘/ fix-all similarly.
    func handleFixAllHotkey() {
        if isNotesWindowKey {
            _ = notesViewModel.fixAllMisspellings()
        } else {
            session.hotkeyFixAll()
        }
    }

    private var isNotesWindowKey: Bool {
        guard let key = NSApp.keyWindow else {
            // If BiSpell is active and a notes window exists, prefer notes.
            return NSApp.isActive && NSApp.windows.contains { isNotesWindow($0) }
        }
        return isNotesWindow(key)
    }

    private func isNotesWindow(_ window: NSWindow) -> Bool {
        if window is NSPanel { return false }
        let title = window.title
        if title.localizedCaseInsensitiveContains("notes") { return true }
        // Untitled SwiftUI document windows still belong to our notes WindowGroup
        if title.isEmpty || title.localizedCaseInsensitiveContains("bispell") {
            return window.isVisible && window.canBecomeKey
        }
        return false
    }

    func showNotesWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeKey && !(window is NSPanel) {
            if isNotesWindow(window) || window.title.isEmpty || window.isVisible {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        NSApp.setActivationPolicy(.regular)
        session.start()
        if !session.accessibilityGranted {
            session.requestAccessibility()
        }
        hotkeys.onHotkey = { [weak self] in
            self?.handleSuggestionHotkey()
        }
        hotkeys.onFixAllHotkey = { [weak self] in
            self?.handleFixAllHotkey()
        }
        hotkeys.register()
        LaunchAtLogin.setEnabled(session.settings.launchAtLogin)
        _ = notesViewModel
    }
}

// Optional focused scene value (reserved for future)
private struct NotesViewModelKey: FocusedValueKey {
    typealias Value = NotesViewModel
}

extension FocusedValues {
    var notesViewModel: NotesViewModel? {
        get { self[NotesViewModelKey.self] }
        set { self[NotesViewModelKey.self] = newValue }
    }
}
