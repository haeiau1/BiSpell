import AppKit
import SwiftUI
import BiSpellCore

@MainActor
final class OverlayController {
    private var markerPanel: NSPanel?
    private var markerView: MarkerCanvasView?
    private var lastMarkerSignature: String = ""

    private var popupWindow: NSPanel?
    private var popupHosting: NSHostingView<SuggestionView>?
    private var currentPopupMisspellingID: String?
    private var currentPopupMisspelling: Misspelling?

    var visiblePopupTarget: Misspelling? {
        guard popupWindow?.isVisible == true else { return nil }
        return currentPopupMisspelling
    }

    private var onPick: ((Misspelling, String) -> Void)?
    private var onAdd: ((Misspelling) -> Void)?
    private var onIgnore: ((Misspelling) -> Void)?
    private var onIgnoreInApp: ((Misspelling) -> Void)?
    private var onDismiss: ((Misspelling) -> Void)?

    func clear() {
        clearMarkersOnly()
        hidePopup()
    }

    func hidePopup() {
        popupWindow?.orderOut(nil)
        currentPopupMisspellingID = nil
        currentPopupMisspelling = nil
    }

    func configureHandlers(
        onPick: @escaping (Misspelling, String) -> Void,
        onAdd: @escaping (Misspelling) -> Void,
        onIgnore: @escaping (Misspelling) -> Void,
        onIgnoreInApp: @escaping (Misspelling) -> Void,
        onDismiss: ((Misspelling) -> Void)? = nil
    ) {
        self.onPick = onPick
        self.onAdd = onAdd
        self.onIgnore = onIgnore
        self.onIgnoreInApp = onIgnoreInApp
        self.onDismiss = onDismiss
    }

    func showMarkers(misspellings: [Misspelling], utf16Offset: Int = 0) {
        guard let element = AXTextAccess.focusedElement() else {
            clearMarkersOnly()
            return
        }

        var segments: [(id: String, rect: CGRect, misspelling: Misspelling)] = []
        for misspelling in misspellings.prefix(30) {
            guard let rect = AXTextAccess.screenRectForMisspelling(
                misspelling,
                element: element,
                utf16Offset: utf16Offset
            ) else { continue }
            let underline = CGRect(
                x: rect.minX,
                y: max(rect.minY - 2, 0),
                width: max(rect.width, 12),
                height: 4
            )
            segments.append((misspelling.id, underline, misspelling))
        }

        let signature = segments.map {
            let r = $0.rect
            return "\($0.id):\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width))"
        }.joined(separator: "|")

        if signature == lastMarkerSignature, markerPanel?.isVisible == true {
            return
        }
        lastMarkerSignature = signature

        guard !segments.isEmpty else {
            clearMarkersOnly()
            return
        }

        let union = segments.map(\.rect).reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -4, dy: -4)
        let panel = ensureMarkerPanel(frame: union)
        guard let view = markerView else { return }

        view.segments = segments.map { seg in
            let local = CGRect(
                x: seg.rect.minX - union.minX,
                y: seg.rect.minY - union.minY,
                width: seg.rect.width,
                height: seg.rect.height
            )
            return MarkerSegment(id: seg.id, rect: local) { [weak self] in
                self?.showPopup(for: seg.misspelling, near: seg.rect, force: true, utf16Offset: utf16Offset)
            }
        }
        view.needsDisplay = true
        panel.setFrame(union, display: true)
        panel.orderFrontRegardless()
    }

    func showOrUpdateAutoPopup(for misspelling: Misspelling?, utf16Offset: Int = 0) {
        guard let misspelling else {
            hidePopup()
            return
        }
        if currentPopupMisspellingID == misspelling.id,
           let popupWindow,
           popupWindow.isVisible {
            if let rect = AXTextAccess.screenRectForMisspelling(misspelling, utf16Offset: utf16Offset) {
                positionPopup(popupWindow, near: rect)
            }
            // Refresh suggestions if they arrived later
            if currentPopupMisspelling?.suggestions != misspelling.suggestions {
                updatePopupContent(misspelling)
            }
            return
        }
        showPopup(for: misspelling, force: false, utf16Offset: utf16Offset)
    }

    func showPopup(for misspelling: Misspelling, near rect: CGRect? = nil, force: Bool = true, utf16Offset: Int = 0) {
        if !force,
           currentPopupMisspellingID == misspelling.id,
           popupWindow?.isVisible == true {
            return
        }

        let panel = ensurePopupPanel()
        updatePopupContent(misspelling)

        let fitting = popupHosting?.fittingSize ?? NSSize(width: 280, height: 120)
        let popupSize = NSSize(width: 280, height: max(fitting.height, 120))

        let anchor = rect
            ?? AXTextAccess.screenRectForMisspelling(misspelling, utf16Offset: utf16Offset)
            ?? caretFallbackRect()
        positionPopup(panel, near: anchor, size: popupSize)
        panel.orderFrontRegardless()
        currentPopupMisspellingID = misspelling.id
        currentPopupMisspelling = misspelling
    }

    func showPopupForFirst(of misspellings: [Misspelling], utf16Offset: Int = 0) {
        guard let first = misspellings.first else { return }
        showPopup(for: first, force: true, utf16Offset: utf16Offset)
    }

    private func updatePopupContent(_ misspelling: Misspelling) {
        guard let panel = popupWindow else { return }
        let content = SuggestionView(
            misspelling: misspelling,
            onPick: { [weak self] suggestion in
                self?.onPick?(misspelling, suggestion)
                self?.hidePopup()
            },
            onAdd: { [weak self] in
                self?.onAdd?(misspelling)
                self?.hidePopup()
            },
            onIgnore: { [weak self] in
                self?.onIgnore?(misspelling)
                self?.hidePopup()
            },
            onIgnoreInApp: { [weak self] in
                self?.onIgnoreInApp?(misspelling)
                self?.hidePopup()
            },
            onDismiss: { [weak self] in
                self?.onDismiss?(misspelling)
                self?.hidePopup()
            }
        )
        if let hosting = popupHosting {
            hosting.rootView = content
        } else {
            let hosting = NSHostingView(rootView: content)
            panel.contentView = hosting
            popupHosting = hosting
        }
        currentPopupMisspelling = misspelling
    }

    private func ensurePopupPanel() -> NSPanel {
        if let popupWindow { return popupWindow }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 250),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.worksWhenModal = true
        popupWindow = panel
        return panel
    }

    private func ensureMarkerPanel(frame: CGRect) -> NSPanel {
        if let markerPanel {
            return markerPanel
        }
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        let view = MarkerCanvasView(frame: NSRect(origin: .zero, size: frame.size))
        panel.contentView = view
        markerView = view
        markerPanel = panel
        return panel
    }

    private func positionPopup(_ panel: NSWindow, near anchor: CGRect, size: NSSize? = nil) {
        let popupSize = size ?? panel.frame.size
        var origin = CGPoint(x: anchor.midX - popupSize.width / 2, y: anchor.minY - popupSize.height - 10)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main {
            if origin.y < screen.visibleFrame.minY + 8 {
                origin.y = min(anchor.maxY + 8, screen.visibleFrame.maxY - popupSize.height)
            }
            origin.x = min(max(origin.x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - popupSize.width - 8)
            origin.y = min(max(origin.y, screen.visibleFrame.minY + 8), screen.visibleFrame.maxY - popupSize.height)
        }
        panel.setFrame(NSRect(origin: origin, size: popupSize), display: true)
    }

    private func clearMarkersOnly() {
        markerPanel?.orderOut(nil)
        lastMarkerSignature = ""
        markerView?.segments = []
    }

    private func caretFallbackRect() -> CGRect {
        let mouse = NSEvent.mouseLocation
        return CGRect(x: mouse.x, y: mouse.y, width: 10, height: 10)
    }
}

private struct MarkerSegment {
    let id: String
    let rect: CGRect
    let onClick: () -> Void
}

private final class MarkerCanvasView: NSView {
    var segments: [MarkerSegment] = []

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.withAlphaComponent(0.9).setFill()
        for seg in segments {
            let path = NSBezierPath(roundedRect: seg.rect, xRadius: 1.5, yRadius: 1.5)
            path.fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for seg in segments where seg.rect.contains(p) {
            seg.onClick()
            return
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        for seg in segments where seg.rect.insetBy(dx: -2, dy: -4).contains(point) {
            return self
        }
        return nil
    }
}

private struct SuggestionView: View {
    let misspelling: Misspelling
    let onPick: (String) -> Void
    let onAdd: () -> Void
    let onIgnore: () -> Void
    let onIgnoreInApp: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("“\(misspelling.word)”")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(misspelling.language.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if misspelling.suggestions.isEmpty {
                Text("No suggestions")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(misspelling.suggestions.enumerated()), id: \.offset) { index, suggestion in
                    Button(action: { onPick(suggestion) }) {
                        HStack {
                            Text(suggestion)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if index == 0 {
                                Text("⌥⌘.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(index == 0 ? .accentColor : nil)
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Button("Add to Dictionary", action: onAdd)
                Button("Ignore", action: onIgnore)
                Button("Ignore in App", action: onIgnoreInApp)
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 280, alignment: .topLeading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}
