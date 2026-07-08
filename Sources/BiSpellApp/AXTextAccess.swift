import AppKit
import ApplicationServices
import BiSpellCore

struct FocusedTextSnapshot: Equatable {
    var appName: String
    var bundleID: String
    var pid: pid_t
    var role: String
    var text: String
    /// UTF-16 offset of `text` within the full field (0 when full value was read).
    var textUTF16Offset: Int
    var selectedRange: NSRange?
    var caretUTF16: Int?
    var elementFrame: CGRect?
    var canReadValue: Bool
    var canReadSelection: Bool
    var canSetValue: Bool
    var isSecure: Bool
    var characterCount: Int?
}

/// Tracks PIDs where we set AXManualAccessibility so we can roll it back.
private final class AXEnableRegistry: @unchecked Sendable {
    static let shared = AXEnableRegistry()
    private let lock = NSLock()
    private var pids = Set<pid_t>()

    func markIfNew(_ pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pids.insert(pid).inserted
    }

    func contains(_ pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pids.contains(pid)
    }

    func allPIDs() -> [pid_t] {
        lock.lock()
        defer { lock.unlock() }
        return Array(pids)
    }

    func remove(_ pid: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        pids.remove(pid)
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        pids.removeAll()
    }
}

// MARK: - Event monitor (AXObserver)

/// Observes AX focus/value/selection changes for one process.
final class AXEventMonitor {
    enum Event {
        case focusedElementChanged
        case valueChanged
        case selectedTextChanged
        case appActivated
    }

    var onEvent: ((Event) -> Void)?

    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var observedAppElement: AXUIElement?
    private var watchedFocusedElement: AXUIElement?
    private var watchingFocused = false

    deinit {
        stop()
    }

    func stop() {
        if let observer {
            if let focused = watchedFocusedElement {
                AXObserverRemoveNotification(observer, focused, kAXValueChangedNotification as CFString)
                AXObserverRemoveNotification(observer, focused, kAXSelectedTextChangedNotification as CFString)
            }
            if let app = observedAppElement {
                AXObserverRemoveNotification(observer, app, kAXFocusedUIElementChangedNotification as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        observedAppElement = nil
        watchedFocusedElement = nil
        observedPID = 0
        watchingFocused = false
    }

    /// Attach to `pid`. Returns false if observer creation / registration fails (caller should poll).
    @discardableResult
    func attach(to pid: pid_t) -> Bool {
        if observedPID == pid, observer != nil { return true }
        stop()

        var newObserver: AXObserver?
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let err = AXObserverCreate(pid, axEventCallback, &newObserver)
        guard err == .success, let newObserver else { return false }

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.5)

        // App-level focus changes
        let focusErr = AXObserverAddNotification(
            newObserver,
            appElement,
            kAXFocusedUIElementChangedNotification as CFString,
            selfPtr
        )

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .commonModes)
        observer = newObserver
        observedPID = pid
        observedAppElement = appElement
        watchingFocused = (focusErr == .success)

        // Best-effort: also watch current focused element for value/selection
        refreshElementNotifications()
        return watchingFocused || focusErr == .success
    }

    func refreshElementNotifications() {
        guard let observer, observedPID != 0 else { return }
        let appElement = observedAppElement ?? AXUIElementCreateApplication(observedPID)
        AXUIElementSetMessagingTimeout(appElement, 0.5)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef else { return }
        let focused = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(focused, 0.5)

        // Drop notifications on the previous focused element to avoid accumulation.
        if let previous = watchedFocusedElement {
            AXObserverRemoveNotification(observer, previous, kAXValueChangedNotification as CFString)
            AXObserverRemoveNotification(observer, previous, kAXSelectedTextChangedNotification as CFString)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        _ = AXObserverAddNotification(observer, focused, kAXValueChangedNotification as CFString, selfPtr)
        _ = AXObserverAddNotification(observer, focused, kAXSelectedTextChangedNotification as CFString, selfPtr)
        watchedFocusedElement = focused
    }

    fileprivate func handle(notification: String) {
        let event: Event
        if notification == (kAXFocusedUIElementChangedNotification as String) {
            refreshElementNotifications()
            event = .focusedElementChanged
        } else if notification == (kAXValueChangedNotification as String) {
            event = .valueChanged
        } else if notification == (kAXSelectedTextChangedNotification as String) {
            event = .selectedTextChanged
        } else {
            event = .valueChanged
        }
        onEvent?(event)
    }
}

private func axEventCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let monitor = Unmanaged<AXEventMonitor>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    DispatchQueue.main.async {
        monitor.handle(notification: name)
    }
}

// MARK: - AXTextAccess

enum AXTextAccess {
    private static let largeDocumentThreshold = 4000
    private static let windowRadius = 500

    static func frontmostApp() -> (name: String, bundleID: String, pid: pid_t)? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return (
            app.localizedName ?? "Unknown",
            app.bundleIdentifier ?? "unknown",
            app.processIdentifier
        )
    }

    static func snapshot(
        deniedBundleIDs: Set<String>,
        electronSupportEnabled: Bool = false
    ) -> FocusedTextSnapshot? {
        guard AccessibilityPermission.isGranted else { return nil }
        guard let front = frontmostApp() else { return nil }
        if deniedBundleIDs.contains(front.bundleID) { return nil }
        if front.bundleID == Bundle.main.bundleIdentifier { return nil }

        let appElement = AXUIElementCreateApplication(front.pid)
        AXUIElementSetMessagingTimeout(appElement, 0.5)

        var focusedRef: CFTypeRef?
        var focusErr = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef)

        // Only nudge Electron-style apps when opted in AND we failed to get focus.
        if (focusErr != .success || focusedRef == nil), electronSupportEnabled {
            enableManualAccessibilityIfNeeded(appElement, pid: front.pid)
            focusErr = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        }

        guard focusErr == .success, let focused = focusedRef else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.5)

        let role = stringAttribute(element, kAXRoleAttribute as CFString) ?? ""
        let subrole = stringAttribute(element, kAXSubroleAttribute as CFString) ?? ""
        let isSecure = role == (kAXTextFieldRole as String) && subrole == (kAXSecureTextFieldSubrole as String)
            || role.lowercased().contains("secure")
        if isSecure { return nil }

        let selected = selectedTextRange(element)
        let frame = frameOfElement(element)
        let canSet = isSettable(element, kAXValueAttribute as CFString)
        let charCount = numberOfCharacters(element)

        let (text, offset, canRead): (String, Int, Bool) = {
            if let charCount, charCount > largeDocumentThreshold, let caret = selected?.location {
                let start = max(0, caret - windowRadius)
                let length = min(charCount - start, windowRadius * 2)
                if length > 0, let window = stringForRange(element, range: NSRange(location: start, length: length)) {
                    return (window, start, true)
                }
            }
            if let value = stringAttribute(element, kAXValueAttribute as CFString) {
                return (value, 0, true)
            }
            return ("", 0, false)
        }()

        let caretInField = selected?.location
        let caretInSnapshot: Int? = {
            guard let caretInField else { return nil }
            return caretInField - offset
        }()
        let selectedInSnapshot: NSRange? = {
            guard let selected else { return nil }
            return NSRange(location: selected.location - offset, length: selected.length)
        }()

        return FocusedTextSnapshot(
            appName: front.name,
            bundleID: front.bundleID,
            pid: front.pid,
            role: role,
            text: text,
            textUTF16Offset: offset,
            selectedRange: selectedInSnapshot,
            caretUTF16: caretInSnapshot,
            elementFrame: frame,
            canReadValue: canRead,
            canReadSelection: selected != nil,
            canSetValue: canSet,
            isSecure: isSecure,
            characterCount: charCount ?? (canRead ? (text as NSString).length + offset : nil)
        )
    }

    /// Lightweight length probe for polling fallback (skip full text read when unchanged).
    static func focusedCharacterCount(deniedBundleIDs: Set<String>) -> (pid: pid_t, bundleID: String, count: Int)? {
        guard AccessibilityPermission.isGranted else { return nil }
        guard let front = frontmostApp() else { return nil }
        if deniedBundleIDs.contains(front.bundleID) { return nil }
        if front.bundleID == Bundle.main.bundleIdentifier { return nil }
        let appElement = AXUIElementCreateApplication(front.pid)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef else { return nil }
        let element = focusedRef as! AXUIElement
        if let n = numberOfCharacters(element) {
            return (front.pid, front.bundleID, n)
        }
        if let value = stringAttribute(element, kAXValueAttribute as CFString) {
            return (front.pid, front.bundleID, (value as NSString).length)
        }
        return nil
    }

    static func supportProbe(electronSupportEnabled: Bool = false) -> AppSupportSample? {
        guard let front = frontmostApp() else { return nil }
        guard AccessibilityPermission.isGranted else {
            return AppSupportSample(
                appName: front.name,
                bundleID: front.bundleID,
                canReadValue: false,
                canReadSelection: false,
                canReadBounds: false,
                notes: "Accessibility permission not granted",
                tier: .c
            )
        }

        let appElement = AXUIElementCreateApplication(front.pid)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        var focusedRef: CFTypeRef?
        var focusErr = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        if (focusErr != .success || focusedRef == nil), electronSupportEnabled {
            enableManualAccessibilityIfNeeded(appElement, pid: front.pid)
            focusErr = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        }
        guard focusErr == .success, let focused = focusedRef else {
            return AppSupportSample(
                appName: front.name,
                bundleID: front.bundleID,
                canReadValue: false,
                canReadSelection: false,
                canReadBounds: false,
                notes: "No focused UI element",
                tier: .c
            )
        }
        let element = focused as! AXUIElement
        let value = stringAttribute(element, kAXValueAttribute as CFString)
        let selected = selectedTextRange(element)
        let bounds = boundsForRange(element, range: NSRange(location: 0, length: min(1, (value as NSString?)?.length ?? 0)))
        let canRead = value != nil
        let canSel = selected != nil
        let canBounds = bounds != nil

        let tier: SupportTier
        if canRead && canSel { tier = .a }
        else if canRead { tier = .b }
        else { tier = .c }

        return AppSupportSample(
            appName: front.name,
            bundleID: front.bundleID,
            canReadValue: canRead,
            canReadSelection: canSel,
            canReadBounds: canBounds,
            notes: "role=\(stringAttribute(element, kAXRoleAttribute as CFString) ?? "?")",
            tier: tier
        )
    }

    static func replaceUTF16Range(
        in snapshotText: String,
        range: NSRange,
        with replacement: String,
        textUTF16Offset: Int = 0,
        useClipboardFallback: Bool
    ) -> Bool {
        guard AccessibilityPermission.isGranted else { return false }
        guard let front = frontmostApp() else { return false }
        let appElement = AXUIElementCreateApplication(front.pid)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else { return false }
        let element = focused as! AXUIElement

        // Map snapshot-local range to full-field coordinates.
        let fieldRange = NSRange(location: range.location + textUTF16Offset, length: range.length)

        let current = stringAttribute(element, kAXValueAttribute as CFString)
        if let current {
            let ns = current as NSString
            guard fieldRange.location + fieldRange.length <= ns.length else { return false }
            let expected = (snapshotText as NSString?).flatMap { snap -> String? in
                range.location + range.length <= snap.length ? snap.substring(with: range) : nil
            }
            if let expected, ns.substring(with: fieldRange) != expected {
                return false
            }
        }

        if setSelectedRange(element, fieldRange) {
            if setStringAttribute(element, kAXSelectedTextAttribute as CFString, replacement) {
                let newCaret = fieldRange.location + (replacement as NSString).length
                _ = setSelectedRange(element, NSRange(location: newCaret, length: 0))
                return true
            }
        }

        if let current {
            let ns = current as NSString
            if fieldRange.location + fieldRange.length <= ns.length {
                let patched = ns.replacingCharacters(in: fieldRange, with: replacement)
                if setStringAttribute(element, kAXValueAttribute as CFString, patched) {
                    let newCaret = fieldRange.location + (replacement as NSString).length
                    _ = setSelectedRange(element, NSRange(location: newCaret, length: 0))
                    return true
                }
            }
        }

        if useClipboardFallback {
            return clipboardReplace(range: fieldRange, replacement: replacement, element: element)
        }
        return false
    }

    // MARK: - Electron / Chromium nudge (opt-in)

    /// Write AXManualAccessibility only (never AXEnhancedUserInterface).
    private static func enableManualAccessibilityIfNeeded(_ appElement: AXUIElement, pid: pid_t) {
        guard AXEnableRegistry.shared.markIfNew(pid) else { return }
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    static func rollbackAccessibilityNudge(pid: pid_t) {
        guard AXEnableRegistry.shared.contains(pid) else { return }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanFalse)
        AXEnableRegistry.shared.remove(pid)
    }

    static func rollbackAllAccessibilityNudges() {
        for pid in AXEnableRegistry.shared.allPIDs() {
            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanFalse)
        }
        AXEnableRegistry.shared.clear()
    }

    private static func clipboardReplace(range: NSRange, replacement: String, element: AXUIElement) -> Bool {
        guard setSelectedRange(element, range) else { return false }
        let pb = NSPasteboard.general
        let previous = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(replacement, forType: .string)

        let source = CGEventSource(stateID: .hidSystemState)
        let keyVDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let keyVUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyVDown?.flags = .maskCommand
        keyVUp?.flags = .maskCommand
        keyVDown?.post(tap: .cghidEventTap)
        keyVUp?.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            pb.clearContents()
            if let previous {
                pb.setString(previous, forType: .string)
            }
        }
        return true
    }

    // MARK: - AX helpers

    static func stringAttribute(_ element: AXUIElement, _ attr: CFString) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr, &ref) == .success, let ref else { return nil }
        return ref as? String
    }

    static func setStringAttribute(_ element: AXUIElement, _ attr: CFString, _ value: String) -> Bool {
        AXUIElementSetAttributeValue(element, attr, value as CFTypeRef) == .success
    }

    static func isSettable(_ element: AXUIElement, _ attr: CFString) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, attr, &settable) == .success else { return false }
        return settable.boolValue
    }

    static func numberOfCharacters(_ element: AXUIElement) -> Int? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &ref) == .success,
              let ref else { return nil }
        if let n = ref as? Int { return n }
        if let n = ref as? NSNumber { return n.intValue }
        return nil
    }

    static func stringForRange(_ element: AXUIElement, range: NSRange) -> String? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var ref: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &ref
        )
        guard err == .success else { return nil }
        return ref as? String
    }

    static func selectedTextRange(_ element: AXUIElement) -> NSRange? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &ref) == .success,
              let ref else { return nil }
        var range = CFRange()
        if AXValueGetValue(ref as! AXValue, .cfRange, &range) {
            return NSRange(location: range.location, length: range.length)
        }
        return nil
    }

    static func setSelectedRange(_ element: AXUIElement, _ range: NSRange) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let axValue = AXValueCreate(.cfRange, &cfRange) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axValue) == .success
    }

    static func frameOfElement(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    static func boundsForRange(_ element: AXUIElement, range: NSRange) -> CGRect? {
        var cfRange = CFRange(location: range.location, length: max(range.length, 1))
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var boundsRef: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsRef
        )
        guard err == .success, let boundsRef else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    static func focusedElement() -> AXUIElement? {
        guard let front = frontmostApp() else { return nil }
        let appElement = AXUIElementCreateApplication(front.pid)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else { return nil }
        return (focused as! AXUIElement)
    }

    /// Bounds for a misspelling. Pass `element` to avoid per-marker focusedElement() calls.
    /// `utf16Offset` is the snapshot window offset into the full field.
    static func screenRectForMisspelling(
        _ misspelling: Misspelling,
        element: AXUIElement? = nil,
        utf16Offset: Int = 0
    ) -> CGRect? {
        let el = element ?? focusedElement()
        guard let el else { return nil }
        let fieldRange = NSRange(
            location: misspelling.utf16Range.location + utf16Offset,
            length: misspelling.utf16Range.length
        )
        if let r = boundsForRange(el, range: fieldRange) {
            return convertAXRectToCocoa(r)
        }
        if let frame = frameOfElement(el) {
            let cocoa = convertAXRectToCocoa(frame)
            return CGRect(x: cocoa.midX - 40, y: cocoa.minY - 4, width: 80, height: 3)
        }
        return nil
    }

    static func convertAXRectToCocoa(_ axRect: CGRect) -> CGRect {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
                ?? NSScreen.main else {
            return axRect
        }
        let screenFrame = screen.frame
        let mainHeight = NSScreen.screens.first?.frame.maxY ?? screenFrame.maxY
        let cocoaY = mainHeight - axRect.origin.y - axRect.height
        return CGRect(x: axRect.origin.x, y: cocoaY, width: axRect.width, height: axRect.height)
    }
}
