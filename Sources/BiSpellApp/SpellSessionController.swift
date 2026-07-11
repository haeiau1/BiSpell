import AppKit
import BiSpellCore
import Combine

@MainActor
final class SpellSessionController: ObservableObject {
    @Published var settings: AppSettings
    @Published var lastSnapshotSummary: String = "Waiting…"
    @Published var lastSupport: AppSupportSample?
    @Published var misspellingCount: Int = 0
    @Published var isPaused: Bool = false {
        didSet {
            if oldValue != isPaused {
                restartMonitoringIfNeeded()
            }
        }
    }
    @Published var accessibilityGranted: Bool = AccessibilityPermission.isGranted

    let engine: SpellEngine
    private let correctionLog = CorrectionLogStore()
    private let settingsStore = SettingsStore()
    private let overlay = OverlayController()

    private var fallbackTimer: Timer?
    private var debounceWork: DispatchWorkItem?
    private var axMonitor = AXEventMonitor()
    private var usingObserver = false
    private var observedPID: pid_t = 0

    private var lastText: String = ""
    private var lastTextOffset: Int = 0
    private var lastCaret: Int? = nil
    private var lastCharCount: Int = -1
    private var lastMisspellings: [Misspelling] = []
    private var lastBundleID: String = ""
    private var supportLog: [AppSupportSample] = []
    /// Dismissed occurrences in the current focused field session (word + UTF-16 range).
    /// Survives re-scans for the same instance; dropped when the text at that range changes.
    private var dismissedOccurrences: [(word: String, location: Int, length: Int)] = []

    private var lastProbeWrite = Date.distantPast
    private var supportDirty = false
    private var workspaceTokens: [NSObjectProtocol] = []
    private var terminateToken: NSObjectProtocol?
    private var isMonitoring = false
    /// Last time an AXObserver event (or successful snapshot) arrived.
    private var lastAXEventAt = Date.distantPast
    /// When true, no readable field — use slower fallback interval.
    private var noFocusedField = false
    private var fallbackInterval: TimeInterval = 1.0

    init() {
        let loaded = SettingsStore().load()
        self.settings = loaded
        do {
            self.engine = try SpellEngine.bundled(settings: loaded)
        } catch {
            fatalError("Failed to load dictionaries: \(error)")
        }
        loadSupportMatrix()
        overlay.configureHandlers(
            onPick: { [weak self] misspelling, suggestion in
                self?.apply(misspelling: misspelling, replacement: suggestion)
            },
            onAdd: { [weak self] misspelling in
                self?.engine.addToDictionary(misspelling.word)
                self?.recheckNow()
            },
            onIgnore: { [weak self] misspelling in
                self?.engine.ignoreWord(misspelling.word)
                self?.recheckNow()
            },
            onIgnoreInApp: { [weak self] misspelling in
                guard let self else { return }
                self.engine.ignoreWord(misspelling.word, inApp: self.lastBundleID)
                self.recheckNow()
            },
            onDismiss: { [weak self] misspelling in
                self?.recordDismissed(misspelling)
            }
        )

        axMonitor.onEvent = { [weak self] event in
            guard let self else { return }
            self.lastAXEventAt = Date()
            self.noFocusedField = false
            self.ensureFallbackInterval(self.usingObserver ? 1.0 : 1.0)
            switch event {
            case .focusedElementChanged:
                self.scheduleProcess(forceFull: true, reason: .focus)
            case .valueChanged:
                self.scheduleProcess(forceFull: true, reason: .value)
            case .selectedTextChanged:
                self.scheduleProcess(forceFull: false, reason: .selection)
            case .appActivated:
                self.scheduleProcess(forceFull: true, reason: .appSwitch)
            }
        }
    }

    deinit {
        // Best-effort; MainActor isolation may not apply in deinit.
    }

    func start() {
        installSystemObserversIfNeeded()
        restartMonitoringIfNeeded()
    }

    func stop() {
        stopMonitoring()
        overlay.clear()
        flushSupportMatrixIfNeeded()
        AXTextAccess.rollbackAllAccessibilityNudges()
    }

    func updateSettings(_ newValue: AppSettings) {
        let electronChanged = settings.electronSupportEnabled != newValue.electronSupportEnabled
        settings = newValue
        settingsStore.save(newValue)
        engine.updateSettings(newValue)
        LaunchAtLogin.setEnabled(newValue.launchAtLogin)
        if electronChanged, !newValue.electronSupportEnabled {
            AXTextAccess.rollbackAllAccessibilityNudges()
        }
        restartMonitoringIfNeeded()
    }

    func toggleEnabled() {
        var s = settings
        s.isEnabled.toggle()
        updateSettings(s)
    }

    func requestAccessibility() {
        AccessibilityPermission.requestIfNeeded()
        accessibilityGranted = AccessibilityPermission.isGranted
    }

    func openAccessibilitySettings() {
        AccessibilityPermission.openSystemSettings()
    }

    func probeSupport() {
        lastSupport = AXTextAccess.supportProbe(electronSupportEnabled: settings.electronSupportEnabled)
        if let sample = lastSupport {
            supportLog.append(sample)
            var map: [String: AppSupportSample] = [:]
            for item in supportLog { map[item.bundleID] = item }
            supportLog = Array(map.values).sorted { $0.appName < $1.appName }
            scheduleSupportMatrixSave()
        }
    }

    func supportMatrix() -> [AppSupportSample] { supportLog }

    func hotkeyCheckSelectionOrFirstMistake() {
        guard settings.hotkeyFallbackEnabled else { return }
        guard settings.isEnabled, !isPaused else { return }

        if let target = overlay.visiblePopupTarget {
            let filled = engine.withSuggestions(target)
            if let first = filled.suggestions.first {
                overlay.hidePopup()
                apply(misspelling: filled, replacement: first)
                return
            }
        }

        if let snap = AXTextAccess.snapshot(
            deniedBundleIDs: settings.deniedBundleIDs,
            electronSupportEnabled: settings.electronSupportEnabled
        ),
           let selected = snap.selectedRange,
           selected.length > 0 {
            let ns = snap.text as NSString
            if selected.location + selected.length <= ns.length {
                let piece = ns.substring(with: selected)
                let result = engine.check(text: piece, bundleID: snap.bundleID, nearCaretOnly: false)
                if let first = result.misspellings.first {
                    var mapped = Misspelling(
                        word: first.word,
                        utf16Range: NSRange(
                            location: selected.location + first.utf16Range.location,
                            length: first.utf16Range.length
                        ),
                        language: first.language,
                        suggestions: []
                    )
                    mapped = engine.withSuggestions(mapped)
                    lastMisspellings = [mapped]
                    lastText = snap.text
                    lastTextOffset = snap.textUTF16Offset
                    overlay.showPopup(for: mapped, force: true, utf16Offset: snap.textUTF16Offset)
                    return
                }
            }
        }

        recheckNow(forceFull: true)
        if let target = engine.nearestMisspelling(in: lastMisspellings, caretUTF16: lastCaret) ?? lastMisspellings.first {
            let filled = engine.withSuggestions(target)
            overlay.showPopup(for: filled, force: true, utf16Offset: lastTextOffset)
        }
    }


    /// ⌥⌘/ — apply top suggestion to every misspelling in selection (or whole field).
    func hotkeyFixAll() {
        guard settings.hotkeyFallbackEnabled else { return }
        guard settings.isEnabled, !isPaused else { return }
        guard accessibilityGranted else { return }

        guard let snap = AXTextAccess.snapshot(
            deniedBundleIDs: settings.deniedBundleIDs,
            electronSupportEnabled: settings.electronSupportEnabled
        ), snap.canReadValue, !snap.text.isEmpty else {
            setIfChanged(\.lastSnapshotSummary, "No readable field")
            return
        }

        let ns = snap.text as NSString
        var checkText = snap.text
        var baseLocation = 0
        if let sel = snap.selectedRange, sel.length > 0,
           sel.location + sel.length <= ns.length {
            checkText = ns.substring(with: sel)
            baseLocation = sel.location
        }

        let result = engine.check(text: checkText, bundleID: snap.bundleID, nearCaretOnly: false)
        var replacements: [TextReplacement] = []
        var skipped = 0
        for m in result.misspellings {
            let filled = engine.withSuggestions(m)
            if let top = filled.suggestions.first {
                let mapped = NSRange(
                    location: baseLocation + filled.utf16Range.location,
                    length: filled.utf16Range.length
                )
                replacements.append(TextReplacement(
                    range: mapped,
                    original: filled.word,
                    replacement: top
                ))
            } else {
                skipped += 1
            }
        }

        var fixed = 0
        for rep in replacements.sorted(by: { $0.range.location > $1.range.location }) {
            let ok = AXTextAccess.replaceUTF16Range(
                in: snap.text,
                range: rep.range,
                with: rep.replacement,
                textUTF16Offset: snap.textUTF16Offset,
                useClipboardFallback: settings.useClipboardFallback
            )
            if ok {
                fixed += 1
                _ = correctionLog.record(wrong: rep.original, correct: rep.replacement)
            } else {
                skipped += 1
            }
        }

        setIfChanged(\.lastSnapshotSummary, "Fixed \(fixed) · skipped \(skipped)")
        if fixed > 0 {
            lastText = ""
            lastCharCount = -1
            recheckNow(forceFull: true)
        }
    }

    func recheckNow(forceFull: Bool = false) {
        lastText = ""
        lastCharCount = -1
        processSnapshot(forceFull: forceFull)
    }

    // MARK: - Monitoring lifecycle

    private enum ProcessReason {
        case value, selection, focus, appSwitch, poll, manual
    }

    private func restartMonitoringIfNeeded() {
        stopMonitoring()
        guard settings.isEnabled, !isPaused else {
            overlay.clear()
            setIfChanged(\.lastSnapshotSummary, isPaused ? "Paused" : "Disabled")
            setIfChanged(\.misspellingCount, 0)
            return
        }
        isMonitoring = true
        attachToFrontmost()
        startFallbackTimer()
        scheduleProcess(forceFull: true, reason: .manual)
    }

    private func stopMonitoring() {
        isMonitoring = false
        debounceWork?.cancel()
        debounceWork = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        axMonitor.stop()
        usingObserver = false
        observedPID = 0
    }

    private func installSystemObserversIfNeeded() {
        guard workspaceTokens.isEmpty else { return }

        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            Task { @MainActor in
                self.handleAppActivation(note)
            }
        })

        terminateToken = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleTerminate()
            }
        }
    }

    private func handleTerminate() {
        flushSupportMatrixIfNeeded()
        AXTextAccess.rollbackAllAccessibilityNudges()
        stopMonitoring()
    }

    private func handleAppActivation(_ note: Notification) {
        // Roll back ManualAccessibility on the app that is leaving the foreground.
        if observedPID != 0,
           let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            let activePID = app.processIdentifier
            if observedPID != activePID {
                AXTextAccess.rollbackAccessibilityNudge(pid: observedPID)
            }
        }
        guard isMonitoring else { return }
        lastAXEventAt = Date()
        attachToFrontmost()
        scheduleProcess(forceFull: true, reason: .appSwitch)
    }

    private func attachToFrontmost() {
        guard let front = AXTextAccess.frontmostApp() else { return }
        if settings.deniedBundleIDs.contains(front.bundleID) {
            axMonitor.stop()
            usingObserver = false
            observedPID = 0
            return
        }
        if front.bundleID == Bundle.main.bundleIdentifier {
            axMonitor.stop()
            usingObserver = false
            observedPID = 0
            return
        }
        if observedPID == front.pid, usingObserver {
            return
        }
        observedPID = front.pid
        usingObserver = axMonitor.attach(to: front.pid)
        lastAXEventAt = Date()
        ensureFallbackInterval(usingObserver ? 5.0 : 1.0)
    }

    private func startFallbackTimer() {
        // Observer healthy → long interval (rarely needed). Poll-only apps → 1s.
        let interval: TimeInterval = usingObserver ? 5.0 : 1.0
        ensureFallbackInterval(interval)
    }

    private func ensureFallbackInterval(_ interval: TimeInterval) {
        if fallbackTimer != nil, abs(fallbackInterval - interval) < 0.01 { return }
        fallbackInterval = interval
        fallbackTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.fallbackTick()
            }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
    }

    /// Safety net only:
    /// - If AXObserver is healthy and recently delivered events → do nothing (idle AX ≈ 0).
    /// - If no event for a while → light length probe; full snapshot only when length changes.
    /// - If no focused text field → back off to 5s.
    private func fallbackTick() {
        guard isMonitoring, settings.isEnabled, !isPaused else { return }
        setIfChanged(\.accessibilityGranted, AccessibilityPermission.isGranted)
        guard accessibilityGranted else { return }

        // Re-attach if frontmost changed without our notification
        if let front = AXTextAccess.frontmostApp(), front.pid != observedPID {
            attachToFrontmost()
            scheduleProcess(forceFull: true, reason: .poll)
            return
        }

        // Healthy observer path: skip probes while events are flowing.
        // Require silence of at least 3s before probing (avoids fighting the observer).
        if usingObserver {
            let silence = Date().timeIntervalSince(lastAXEventAt)
            if silence < 3.0 {
                return
            }
            // While silent with a known non-empty field, length-only check is enough.
            if let probe = AXTextAccess.focusedCharacterCount(deniedBundleIDs: settings.deniedBundleIDs) {
                noFocusedField = false
                ensureFallbackInterval(5.0)
                if probe.count == lastCharCount {
                    return
                }
                scheduleProcess(forceFull: true, reason: .poll)
                return
            }
            // No focused text element (Finder, desktop, etc.) — back off.
            noFocusedField = true
            ensureFallbackInterval(5.0)
            if !lastText.isEmpty {
                lastText = ""
                lastMisspellings = []
                lastCharCount = -1
                overlay.clear()
                setIfChanged(\.misspellingCount, 0)
            }
            return
        }

        // Observer unavailable: 1s poll with length-only short-circuit.
        ensureFallbackInterval(1.0)
        if let probe = AXTextAccess.focusedCharacterCount(deniedBundleIDs: settings.deniedBundleIDs) {
            noFocusedField = false
            if probe.count == lastCharCount, !lastText.isEmpty {
                return
            }
            scheduleProcess(forceFull: true, reason: .poll)
            return
        }
        noFocusedField = true
        ensureFallbackInterval(5.0)
        if !lastText.isEmpty {
            lastText = ""
            lastMisspellings = []
            lastCharCount = -1
            overlay.clear()
            setIfChanged(\.misspellingCount, 0)
        }
    }

    private func scheduleProcess(forceFull: Bool, reason: ProcessReason) {
        guard isMonitoring, settings.isEnabled, !isPaused else { return }
        debounceWork?.cancel()
        let delayMs = max(50, settings.debounceMilliseconds)
        let work = DispatchWorkItem { [weak self] in
            self?.processSnapshot(forceFull: forceFull)
        }
        debounceWork = work
        // Selection-only can be slightly snappier for caret popup
        let delay = reason == .selection ? min(delayMs, 120) : delayMs
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay), execute: work)
    }

    private func processSnapshot(forceFull: Bool) {
        setIfChanged(\.accessibilityGranted, AccessibilityPermission.isGranted)
        guard accessibilityGranted else {
            setIfChanged(\.lastSnapshotSummary, "Grant Accessibility permission")
            overlay.clear()
            return
        }
        guard settings.isEnabled, !isPaused else {
            overlay.clear()
            setIfChanged(\.lastSnapshotSummary, isPaused ? "Paused" : "Disabled")
            return
        }

        guard let snap = AXTextAccess.snapshot(
            deniedBundleIDs: settings.deniedBundleIDs,
            electronSupportEnabled: settings.electronSupportEnabled
        ) else {
            setIfChanged(\.lastSnapshotSummary, "No readable field")
            setIfChanged(\.misspellingCount, 0)
            overlay.clear()
            lastMisspellings = []
            noFocusedField = true
            ensureFallbackInterval(5.0)
            return
        }
        noFocusedField = false
        lastAXEventAt = Date()

        // New app / empty field: dismissals are session-local to the focused document.
        if lastBundleID != snap.bundleID {
            dismissedOccurrences = []
        }
        lastBundleID = snap.bundleID
        let previousText = lastText
        let previousOffset = lastTextOffset
        lastTextOffset = snap.textUTF16Offset
        setIfChanged(
            \.lastSnapshotSummary,
            "\(snap.appName) · \(snap.role) · \(snap.canReadValue ? "read✓" : "read✗")\(usingObserver ? " · evt" : " · poll")"
        )

        if lastSupport?.bundleID != snap.bundleID {
            probeSupport()
        }

        guard snap.canReadValue, !snap.text.isEmpty else {
            overlay.clear()
            setIfChanged(\.misspellingCount, 0)
            lastMisspellings = []
            lastText = ""
            lastCharCount = snap.characterCount ?? 0
            dismissedOccurrences = []
            return
        }

        let textChanged = snap.text != lastText
        let caretChanged = snap.caretUTF16 != lastCaret
        lastCharCount = snap.characterCount ?? ((snap.text as NSString).length + snap.textUTF16Offset)

        if !forceFull, !textChanged, !caretChanged {
            return
        }

        if textChanged || forceFull {
            // Shift/drop dismissals for the inferred edit before pruning, so typing before a
            // dismissed word keeps that same instance dismissed (not only exact-range prune).
            // Ranges are snapshot-local (engine + recordDismissed + caret); keep that frame
            // while the window offset is stable, and rebase/drop when it slides.
            if textChanged {
                dismissedOccurrences = reconcileDismissed(
                    dismissedOccurrences,
                    previousText: previousText,
                    previousOffset: previousOffset,
                    newText: snap.text,
                    newOffset: snap.textUTF16Offset,
                    previousCaret: lastCaret,
                    newCaret: snap.caretUTF16
                )
            } else if previousOffset != snap.textUTF16Offset {
                let delta = previousOffset - snap.textUTF16Offset
                let rebased = dismissedOccurrences.map {
                    ($0.word, $0.location + delta, $0.length)
                }
                dismissedOccurrences = pruneDismissed(rebased, in: snap.text)
            } else {
                dismissedOccurrences = pruneDismissed(dismissedOccurrences, in: snap.text)
            }
            lastText = snap.text
            // Windowed snapshots already bound the document; only further-narrow full reads.
            let fullLen = snap.characterCount ?? ((snap.text as NSString).length + snap.textUTF16Offset)
            let largeFullRead = fullLen > 4000 && snap.textUTF16Offset == 0
            let result = engine.check(
                text: snap.text,
                caretUTF16: snap.caretUTF16,
                bundleID: snap.bundleID,
                nearCaretOnly: largeFullRead
            )
            let visible = result.misspellings.filter { !isDismissed($0) }
            lastMisspellings = visible
            setIfChanged(\.misspellingCount, visible.count)
            overlay.showMarkers(misspellings: visible, utf16Offset: snap.textUTF16Offset)
        } else if caretChanged {
            // Positions may have scrolled; cheap reposition without re-check
            overlay.showMarkers(misspellings: lastMisspellings, utf16Offset: snap.textUTF16Offset)
        }

        lastCaret = snap.caretUTF16
        updateAutoPopup(caret: snap.caretUTF16)
    }

    private func updateAutoPopup(caret: Int?) {
        guard let target = engine.nearestMisspelling(in: lastMisspellings, caretUTF16: caret) else {
            overlay.hidePopup()
            return
        }

        if let caret {
            let start = target.utf16Range.location
            let end = target.utf16Range.location + target.utf16Range.length
            let near = caret >= start - 1 && caret <= end + 2
            if !near {
                overlay.hidePopup()
                return
            }
        }

        if isDismissed(target) {
            overlay.hidePopup()
            return
        }

        let filled = engine.withSuggestions(target)
        guard !filled.suggestions.isEmpty else {
            overlay.hidePopup()
            return
        }

        overlay.showOrUpdateAutoPopup(for: filled, utf16Offset: lastTextOffset)
    }

    private func recordDismissed(_ misspelling: Misspelling) {
        let entry = (
            word: misspelling.word,
            location: misspelling.utf16Range.location,
            length: misspelling.utf16Range.length
        )
        if !dismissedOccurrences.contains(where: {
            $0.word == entry.word && $0.location == entry.location && $0.length == entry.length
        }) {
            dismissedOccurrences.append(entry)
        }
        // Drop from live list + markers so click/nearest cannot re-show this instance
        // until the next full recheck (which also filters via isDismissed).
        lastMisspellings.removeAll {
            $0.word == entry.word
                && $0.utf16Range.location == entry.location
                && $0.utf16Range.length == entry.length
        }
        setIfChanged(\.misspellingCount, lastMisspellings.count)
        overlay.hidePopup()
        overlay.showMarkers(misspellings: lastMisspellings, utf16Offset: lastTextOffset)
    }

    private func isDismissed(_ misspelling: Misspelling) -> Bool {
        dismissedOccurrences.contains {
            $0.word == misspelling.word
                && $0.location == misspelling.utf16Range.location
                && $0.length == misspelling.utf16Range.length
        }
    }

    /// After a text change, shift/drop dismissed ranges then prune by verifying substrings.
    /// Dismiss locations, misspelling ranges, and caret are **snapshot-local** (relative to the
    /// AX window text, not the full field). While `previousOffset == newOffset`, edits stay in
    /// that local frame. When the window slides, locations are rebased by the offset delta (or
    /// dropped if they fall outside the new snapshot after prune).
    private func reconcileDismissed(
        _ items: [(word: String, location: Int, length: Int)],
        previousText: String,
        previousOffset: Int,
        newText: String,
        newOffset: Int,
        previousCaret: Int?,
        newCaret: Int?
    ) -> [(word: String, location: Int, length: Int)] {
        guard !items.isEmpty else { return items }

        // Window slid: snapshots are different slices of the field — do not infer edits across
        // unrelated windows. Rebase snapshot-local → absolute → new-local, then prune.
        if previousOffset != newOffset {
            let rebase = previousOffset - newOffset
            let rebased = items.map { ($0.word, $0.location + rebase, $0.length) }
            return pruneDismissed(rebased, in: newText)
        }

        guard !previousText.isEmpty else {
            return pruneDismissed(items, in: newText)
        }

        if let edit = Self.inferSingleEdit(from: previousText, to: newText) {
            // Snapshot-local edit — do not add field offset.
            return adjustDismissed(
                items,
                edited: edit.edited,
                replacementLength: edit.replacementLength,
                in: newText
            )
        }

        // Inference unavailable: try caret-anchored pure insert/delete (caret is snapshot-local).
        let prevLen = (previousText as NSString).length
        let newLen = (newText as NSString).length
        let lengthDelta = newLen - prevLen
        if lengthDelta != 0, let caret = previousCaret ?? newCaret {
            let deletedLen = max(0, -lengthDelta)
            let insertedLen = max(0, lengthDelta)
            // Prefer end-of-edit caret when available (after insert, caret is often at edit end).
            let editStart: Int
            if let newCaret, lengthDelta > 0 {
                editStart = max(0, newCaret - lengthDelta)
            } else if let previousCaret {
                editStart = max(0, previousCaret - (lengthDelta < 0 ? deletedLen : 0))
            } else {
                editStart = max(0, caret - (lengthDelta < 0 ? deletedLen : 0))
            }
            return adjustDismissed(
                items,
                edited: NSRange(location: editStart, length: deletedLen),
                replacementLength: insertedLen,
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

    /// Shift or drop dismissed occurrences after a text edit (same rules as notes `adjustDismissed`).
    /// `edited` and item locations are in the same coordinate frame (snapshot-local).
    private func adjustDismissed(
        _ items: [(word: String, location: Int, length: Int)],
        edited: NSRange,
        replacementLength: Int,
        in text: String
    ) -> [(word: String, location: Int, length: Int)] {
        let delta = replacementLength - edited.length
        let editEnd = edited.location + edited.length
        var result: [(word: String, location: Int, length: Int)] = []
        for item in items {
            let spanEnd = item.location + item.length
            if editEnd <= item.location {
                // Edit entirely before this occurrence — shift.
                result.append((item.word, item.location + delta, item.length))
            } else if edited.location >= spanEnd {
                // Edit entirely after — keep.
                result.append(item)
            }
            // Overlap / replace of the dismissed instance: drop so a retyped word can re-flag.
        }
        return pruneDismissed(result, in: text)
    }

    /// Keep only dismissals whose word still sits at the recorded **snapshot-local** UTF-16 range.
    private func pruneDismissed(
        _ items: [(word: String, location: Int, length: Int)],
        in text: String
    ) -> [(word: String, location: Int, length: Int)] {
        let ns = text as NSString
        let localLen = ns.length
        return items.filter { item in
            guard item.length > 0,
                  item.location >= 0,
                  item.location + item.length <= localLen else {
                // Outside current snapshot window — drop (cannot validate).
                return false
            }
            let slice = ns.substring(with: NSRange(location: item.location, length: item.length))
            return slice == item.word
        }
    }

    private func apply(misspelling: Misspelling, replacement: String) {
        let ok = AXTextAccess.replaceUTF16Range(
            in: lastText,
            range: misspelling.utf16Range,
            with: replacement,
            textUTF16Offset: lastTextOffset,
            useClipboardFallback: settings.useClipboardFallback
        )
        if ok {
            shiftDismissalsAfterApply(misspelling: misspelling, replacement: replacement)
            lastText = ""
            lastCharCount = -1
            recheckNow(forceFull: true)
        } else {
            let retry = AXTextAccess.replaceUTF16Range(
                in: lastText,
                range: misspelling.utf16Range,
                with: replacement,
                textUTF16Offset: lastTextOffset,
                useClipboardFallback: true
            )
            if retry {
                shiftDismissalsAfterApply(misspelling: misspelling, replacement: replacement)
                lastText = ""
                lastCharCount = -1
                recheckNow(forceFull: true)
            } else {
                lastSnapshotSummary = "Replace failed in this app"
            }
        }
    }

    /// Drop the applied occurrence and shift later dismissals by the replacement length delta.
    private func shiftDismissalsAfterApply(misspelling: Misspelling, replacement: String) {
        let edit = misspelling.utf16Range
        let replLen = (replacement as NSString).length
        let delta = replLen - edit.length
        let editEnd = edit.location + edit.length
        dismissedOccurrences = dismissedOccurrences.compactMap { item in
            if item.location == edit.location, item.length == edit.length, item.word == misspelling.word {
                return nil
            }
            let spanEnd = item.location + item.length
            if editEnd <= item.location {
                return (item.word, item.location + delta, item.length)
            }
            if edit.location >= spanEnd {
                return item
            }
            return nil
        }
    }

    // MARK: - Denylist & personal dictionary

    func addDeniedBundleID(_ bundleID: String) {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var s = settings
        s.deniedBundleIDs.insert(trimmed)
        updateSettings(s)
    }

    func removeDeniedBundleID(_ bundleID: String) {
        var s = settings
        s.deniedBundleIDs.remove(bundleID)
        updateSettings(s)
    }

    func removeDictionaryWord(_ word: String) {
        objectWillChange.send()
        engine.removeFromDictionary(word)
        recheckNow()
    }

    func unignoreWord(_ word: String) {
        objectWillChange.send()
        engine.unignoreWord(word)
        recheckNow()
    }

    // MARK: - Helpers

    private func setIfChanged<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<SpellSessionController, T>, _ value: T) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }

    private var supportMatrixURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BiSpell", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("support-matrix.json")
    }

    private func loadSupportMatrix() {
        guard let data = try? Data(contentsOf: supportMatrixURL),
              let decoded = try? JSONDecoder().decode([AppSupportSample].self, from: data) else { return }
        supportLog = decoded.sorted { $0.appName < $1.appName }
    }

    private func scheduleSupportMatrixSave() {
        supportDirty = true
        let elapsed = Date().timeIntervalSince(lastProbeWrite)
        if elapsed >= 60 {
            flushSupportMatrixIfNeeded()
        }
    }

    private func flushSupportMatrixIfNeeded() {
        guard supportDirty else { return }
        if let data = try? JSONEncoder().encode(supportLog) {
            try? data.write(to: supportMatrixURL, options: .atomic)
        }
        lastProbeWrite = Date()
        supportDirty = false
    }
}
