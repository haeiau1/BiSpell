import AppKit
import SwiftUI
import BiSpellCore

/// NSTextView with caret tracking, word-boundary hooks, and reliable ⌘1–⌘5 capture.
struct NoteTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selectedRange: NSRange
    /// When non-nil, show floating suggestion popup near the misspelling/caret.
    var activeMisspelling: Misspelling?
    var lockedSpans: [LockedSpan] = []
    var editorFont: NSFont = .systemFont(ofSize: NSFont.systemFontSize + 1)
    var textColor: NSColor = .textColor
    var backgroundColor: NSColor = .textBackgroundColor
    var lockedBackgroundColor: NSColor = NSColor.systemYellow.withAlphaComponent(0.22)
    var isEditable: Bool = true
    var onEditingChanged: (() -> Void)?
    /// Fired after the user types a word boundary (space / punctuation / newline).
    var onWordBoundary: (() -> Void)?
    /// ⌘1…⌘5 while the editor is first responder.
    var onCommandNumber: ((Int) -> Void)?
    var onApplySuggestion: ((String, Misspelling) -> Void)?
    var onDismissSuggestions: (() -> Void)?
    /// Return false to block edits that hit locked spans.
    var canEdit: ((NSRange, String) -> Bool)?
    /// After NSTextView applies an allowed edit (A1): commit model + span adjust.
    var commitEditorChange: ((String, NSRange, String, [LockedSpan]) -> Void)?
    /// Smart multi-delete of unlocked segments (B3).
    var smartDelete: ((NSRange) -> Void)?
    /// Snapshot of locked spans before an edit (for commit).
    var currentLockedSpans: () -> [LockedSpan] = { [] }
    var onBlockedEdit: (() -> Void)?
    var restoreSnapshot: ((String, [LockedSpan], NSRange) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let textView = NoteNSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = editorFont
        textView.textColor = textColor
        textView.insertionPointColor = textColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scroll.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.string = text
        textView.setSelectedRange(clampRange(selectedRange, in: text))
        textView.isEditable = isEditable
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.backgroundColor = backgroundColor
        scroll.backgroundColor = backgroundColor
        scroll.drawsBackground = true
        textView.onCommandNumber = { [weak coordinator = context.coordinator] n in
            coordinator?.parent.onCommandNumber?(n)
        }
        textView.onEscape = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onDismissSuggestions?()
        }

        scroll.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.installKeyMonitor()
        context.coordinator.paintLockedSpans(force: true)
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NoteNSTextView else { return }
        context.coordinator.parent = self
        textView.onCommandNumber = { [weak coordinator = context.coordinator] n in
            coordinator?.parent.onCommandNumber?(n)
        }
        textView.onEscape = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onDismissSuggestions?()
        }

        if textView.string != text {
            let saved = textView.selectedRange()
            textView.string = text
            // Prefer external selectedRange when body was replaced by a suggestion.
            let range = clampRange(selectedRange, in: text)
            if range.length == 0 && range.location != saved.location {
                textView.setSelectedRange(range)
            } else {
                textView.setSelectedRange(clampRange(saved, in: text))
            }
        } else {
            let desired = clampRange(selectedRange, in: text)
            if textView.selectedRange() != desired {
                textView.setSelectedRange(desired)
            }
        }
        textView.isEditable = isEditable
        if textView.font != editorFont {
            textView.font = editorFont
        }
        if textView.textColor != textColor {
            textView.textColor = textColor
            textView.insertionPointColor = textColor
        }
        if textView.backgroundColor != backgroundColor {
            textView.backgroundColor = backgroundColor
            scrollView.backgroundColor = backgroundColor
        }
        context.coordinator.paintLockedSpans(force: false)
        context.coordinator.syncSuggestionPopup()
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    private func clampRange(_ range: NSRange, in text: String) -> NSRange {
        let len = (text as NSString).length
        let loc = min(max(0, range.location), len)
        let maxLen = max(0, len - loc)
        let length = min(max(0, range.length), maxLen)
        return NSRange(location: loc, length: length)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteTextEditor
        weak var textView: NoteNSTextView?
        private var keyMonitor: Any?
        private var popup: NotesSuggestionPanel?
        /// Captured in shouldChangeTextIn for the return-true undo path (A1).
        private var pendingEdit: (range: NSRange, replacement: String, preSpans: [LockedSpan])?
        private var lastPaintSignature: String = ""
        /// Prevent re-entrant textDidChange while smart-delete mutates storage.
        private var isProgrammaticEdit = false

        init(_ parent: NoteTextEditor) {
            self.parent = parent
        }

        func installKeyMonitor() {
            guard keyMonitor == nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let textView = self.textView else { return event }
                // Only when this editor (or its field editor chain) is focused.
                guard let window = textView.window, window.isKeyWindow else { return event }
                let fr = window.firstResponder
                let isUs = fr === textView || (fr as? NSView)?.isDescendant(of: textView) == true
                guard isUs else { return event }

                if event.modifierFlags.contains(.command),
                   !event.modifierFlags.contains(.shift),
                   !event.modifierFlags.contains(.option),
                   !event.modifierFlags.contains(.control),
                   let chars = event.charactersIgnoringModifiers,
                   chars.count == 1,
                   let n = Int(chars),
                   (1...5).contains(n) {
                    self.parent.onCommandNumber?(n)
                    return nil
                }
                if event.keyCode == 53 { // Escape
                    self.parent.onDismissSuggestions?()
                    return nil
                }
                return event
            }
        }

        func teardown() {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
            popup?.close()
            popup = nil
        }

        deinit {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
            }
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            if isProgrammaticEdit { return true }
            let replacement = replacementString ?? ""
            let spans = parent.currentLockedSpans()

            // B3: pure deletion over mixed locked/unlocked selection → smart delete.
            if replacement.isEmpty, affectedCharRange.length > 0,
               LockedSpanMath.isMixedSelection(affectedCharRange, spans: spans) {
                performSmartDelete(in: textView, range: affectedCharRange)
                return false
            }

            // Fully locked (or insertion inside lock): block.
            if LockedSpanMath.anyBlocks(spans, edit: affectedCharRange) {
                // Mixed typing-over-selection is also blocked here (not pure deletion).
                NSSound.beep()
                parent.onBlockedEdit?()
                return false
            }
            if let canEdit = parent.canEdit, !canEdit(affectedCharRange, replacement) {
                NSSound.beep()
                parent.onBlockedEdit?()
                return false
            }

            // A1: let NSTextView apply (registers undo); commit model in textDidChange.
            pendingEdit = (affectedCharRange, replacement, spans)
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            if isProgrammaticEdit { return }

            let newText = textView.string
            let oldText = parent.text
            let caret = textView.selectedRange().location

            if let pending = pendingEdit {
                pendingEdit = nil
                parent.commitEditorChange?(newText, pending.range, pending.replacement, pending.preSpans)
            } else if newText != oldText {
                // Fallback (paste etc. without pending) — replace whole model text, clamp spans.
                parent.text = newText
            }

            parent.selectedRange = textView.selectedRange()
            parent.onEditingChanged?()
            paintLockedSpans(force: false)

            if didCrossWordBoundary(from: oldText, to: newText, caret: caret) {
                DispatchQueue.main.async { [weak self] in
                    self?.parent.onWordBoundary?()
                }
            }
        }

        private func performSmartDelete(in textView: NSTextView, range: NSRange) {
            let beforeText = textView.string
            let beforeSpans = parent.currentLockedSpans()
            let beforeSel = textView.selectedRange()
            parent.smartDelete?(range)
            // Sync text view from model
            let afterText = parent.text
            let afterSel = parent.selectedRange
            isProgrammaticEdit = true
            if let storage = textView.textStorage {
                storage.beginEditing()
                storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: afterText)
                storage.endEditing()
            } else {
                textView.string = afterText
            }
            textView.setSelectedRange(afterSel)
            isProgrammaticEdit = false
            paintLockedSpans(force: true)
            parent.onEditingChanged?()

            // One undo step restoring text + locks (A1/B3).
            if let um = textView.undoManager {
                um.registerUndo(withTarget: textView) { [weak self] tv in
                    guard let self else { return }
                    self.parent.restoreSnapshot?(beforeText, beforeSpans, beforeSel)
                    self.isProgrammaticEdit = true
                    if let storage = tv.textStorage {
                        storage.beginEditing()
                        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: beforeText)
                        storage.endEditing()
                    } else {
                        tv.string = beforeText
                    }
                    tv.setSelectedRange(beforeSel)
                    self.isProgrammaticEdit = false
                    self.paintLockedSpans(force: true)
                }
                um.setActionName("Smart Delete")
            }
            _ = afterText
        }

                func paintLockedSpans(force: Bool = true) {
            guard let textView, let storage = textView.textStorage else { return }
            let sig = paintSignature(storageLength: storage.length)
            if !force, sig == lastPaintSignature { return }
            lastPaintSignature = sig

            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.removeAttribute(.backgroundColor, range: full)
            storage.addAttribute(.foregroundColor, value: parent.textColor, range: full)
            storage.addAttribute(.font, value: parent.editorFont, range: full)
            for span in parent.lockedSpans {
                var r = span.utf16Range
                if r.location >= storage.length { continue }
                if r.location + r.length > storage.length {
                    r.length = storage.length - r.location
                }
                guard r.length > 0 else { continue }
                storage.addAttribute(.backgroundColor, value: parent.lockedBackgroundColor, range: r)
            }
            storage.endEditing()
        }

        private func paintSignature(storageLength: Int) -> String {
            let spans = parent.lockedSpans.map { "\($0.location):\($0.length)" }.joined(separator: ",")
            let fontName = parent.editorFont.fontName
            let fontSize = parent.editorFont.pointSize
            // Color identity via description is enough for theme switches.
            return "\(storageLength)|\(spans)|\(fontName)|\(fontSize)|\(parent.textColor)|\(parent.lockedBackgroundColor)|\(parent.backgroundColor)"
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            let range = textView.selectedRange()
            if parent.selectedRange != range {
                parent.selectedRange = range
            }
        }

        func syncSuggestionPopup() {
            guard let textView else { return }
            guard let miss = parent.activeMisspelling, !miss.suggestions.isEmpty else {
                popup?.orderOut(nil)
                return
            }
            if popup == nil {
                popup = NotesSuggestionPanel()
                popup?.onPick = { [weak self] suggestion in
                    guard let self, let m = self.parent.activeMisspelling else { return }
                    self.parent.onApplySuggestion?(suggestion, m)
                }
                popup?.onDismiss = { [weak self] in
                    self?.parent.onDismissSuggestions?()
                }
            }
            popup?.update(misspelling: miss)
            let anchor = caretRectInScreen(textView: textView, utf16Range: miss.utf16Range)
                ?? caretRectInScreen(textView: textView, utf16Range: textView.selectedRange())
                ?? .zero
            popup?.position(near: anchor)
            popup?.orderFront(nil)
        }

        private func didCrossWordBoundary(from old: String, to new: String, caret: Int) -> Bool {
            guard new.count >= old.count else { return false }
            // Inserted characters ending with boundary.
            let ns = new as NSString
            guard caret > 0, caret <= ns.length else { return false }
            let last = ns.substring(with: NSRange(location: caret - 1, length: 1))
            guard isBoundary(last) else { return false }
            // Avoid firing on every space if nothing letter-like before.
            if caret >= 2 {
                let prev = ns.substring(with: NSRange(location: caret - 2, length: 1))
                if isBoundary(prev) { return false }
            }
            return true
        }

        private func isBoundary(_ s: String) -> Bool {
            guard let ch = s.unicodeScalars.first else { return false }
            return CharacterSet.whitespacesAndNewlines.contains(ch)
                || CharacterSet.punctuationCharacters.contains(ch)
        }

        private func caretRectInScreen(textView: NSTextView, utf16Range: NSRange) -> CGRect? {
            guard let layout = textView.layoutManager,
                  let container = textView.textContainer else { return nil }
            let len = (textView.string as NSString).length
            guard utf16Range.location <= len else { return nil }
            let loc = min(utf16Range.location, max(0, len - 1))
            let glyphRange = layout.glyphRange(
                forCharacterRange: NSRange(location: loc, length: max(utf16Range.length, 1)),
                actualCharacterRange: nil
            )
            var rect = layout.boundingRect(forGlyphRange: glyphRange, in: container)
            rect.origin.x += textView.textContainerOrigin.x
            rect.origin.y += textView.textContainerOrigin.y
            let inWindow = textView.convert(rect, to: nil)
            guard let window = textView.window else { return nil }
            return window.convertToScreen(inWindow)
        }
    }
}

/// Captures ⌘1–⌘5 / Esc before NSTextView default handling.
final class NoteNSTextView: NSTextView {
    var onCommandNumber: ((Int) -> Void)?
    var onEscape: (() -> Void)?

    /// Copy full selection (including locked text), then delete via normal pipeline (smart-delete if mixed).
    override func cut(_ sender: Any?) {
        copy(sender)
        let range = selectedRange()
        guard range.length > 0 else { return }
        if shouldChangeText(in: range, replacementString: "") {
            // Fully unlocked deletion — let default path run through replace + didChangeText
            textStorage?.replaceCharacters(in: range, with: "")
            setSelectedRange(NSRange(location: range.location, length: 0))
            didChangeText()
        }
        // Mixed/locked: shouldChangeText returned false after handling (smart delete or block).
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.option),
           !event.modifierFlags.contains(.control),
           let chars = event.charactersIgnoringModifiers,
           chars.count == 1,
           let n = Int(chars),
           (1...5).contains(n) {
            onCommandNumber?(n)
            return true
        }
        if event.type == .keyDown, event.keyCode == 53 {
            onEscape?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           let chars = event.charactersIgnoringModifiers,
           chars.count == 1,
           let n = Int(chars),
           (1...5).contains(n) {
            onCommandNumber?(n)
            return
        }
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Floating suggestion panel

final class NotesSuggestionPanel: NSPanel {
    var onPick: ((String) -> Void)?
    var onDismiss: (() -> Void)?

    private let stack = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "⌘1 top · ⌘2…⌘5 · Esc dismiss")

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true

        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        box.layer?.cornerRadius = 10
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.cgColor

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        hintLabel.font = .systemFont(ofSize: 10)
        hintLabel.textColor = .secondaryLabelColor

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.translatesAutoresizingMaskIntoConstraints = false

        contentView = box
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            stack.topAnchor.constraint(equalTo: box.topAnchor),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            box.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            box.widthAnchor.constraint(lessThanOrEqualToConstant: 420)
        ])
    }

    func update(misspelling: Misspelling) {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        titleLabel.stringValue = "“\(misspelling.word)” · \(misspelling.language.displayName)"
        stack.addArrangedSubview(titleLabel)

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY

        for (index, suggestion) in misspelling.suggestions.prefix(5).enumerated() {
            let button = NSButton(
                title: "\(index + 1)  \(suggestion)",
                target: self,
                action: #selector(pickButton(_:))
            )
            button.bezelStyle = .rounded
            button.setButtonType(.momentaryPushIn)
            if index == 0 {
                button.keyEquivalent = "1"
                button.keyEquivalentModifierMask = .command
            }
            button.identifier = NSUserInterfaceItemIdentifier(suggestion)
            button.font = .systemFont(ofSize: 12)
            row.addArrangedSubview(button)
        }
        stack.addArrangedSubview(row)
        stack.addArrangedSubview(hintLabel)

        stack.layoutSubtreeIfNeeded()
        let fitting = stack.fittingSize
        setContentSize(NSSize(width: max(280, fitting.width + 8), height: fitting.height + 4))
    }

    func position(near anchor: CGRect) {
        var origin = CGPoint(x: anchor.minX, y: anchor.minY - frame.height - 8)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main {
            if origin.y < screen.visibleFrame.minY + 4 {
                origin.y = min(anchor.maxY + 8, screen.visibleFrame.maxY - frame.height)
            }
            origin.x = min(
                max(origin.x, screen.visibleFrame.minX + 8),
                screen.visibleFrame.maxX - frame.width - 8
            )
        }
        setFrameOrigin(origin)
    }

    @objc private func pickButton(_ sender: NSButton) {
        onPick?(sender.identifier?.rawValue ?? sender.title)
    }
}
