import AppKit
import Foundation
import BiSpellCore

/// Lets the view model apply text changes through the live NSTextView so ⌘Z works.
final class NoteEditorBridge {
    /// Set by NoteTextEditor.Coordinator when the editor is alive.
    weak var coordinator: NoteTextEditor.Coordinator?

    var isConnected: Bool { coordinator != nil }

    @MainActor
    func replace(range: NSRange, with replacement: String, actionName: String = "Spelling") {
        coordinator?.performUndoableReplacement(range: range, replacement: replacement, actionName: actionName)
    }

    @MainActor
    func replaceMany(_ items: [(range: NSRange, replacement: String)], actionName: String = "Fix All") {
        coordinator?.performUndoableReplacements(items, actionName: actionName)
    }
}
