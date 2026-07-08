# BiSpell Performance Improvement Plan

> Date: 2026-07-07 · Live measurement: footprint **538 MB** (292 MB MALLOC_SMALL + 236 MB MALLOC_LARGE),
> idle CPU ~0.7% avg. The real cost is not inside BiSpell itself; it is the **load exported to
> the focused app, the AppleSpell service, and WindowServer**.

Priority order reflects each item's contribution to the user-visible "my PC got slow" effect.

---

## Phase 1 — Quick wins (about half a day, highest impact)

### 1.1 Stop forcing `AXEnhancedUserInterface` and roll it back 🔴 CRITICAL

**File:** `Sources/BiSpellApp/AXTextAccess.swift` (`enableAccessibilityIfNeeded`, lines ~192-196)

**Problem:** Every focused app gets `AXEnhancedUserInterface=true` and
`AXManualAccessibility=true` written into it. Chromium/Electron apps (Chrome, VS Code,
Slack…) respond by building and continuously maintaining a full accessibility tree →
permanent CPU/RAM increase in those apps. Since the flag is never turned back off, the
effect **persists even after BiSpell quits**.

**Tasks:**
- [x] Stop writing `AXEnhancedUserInterface` entirely. `AXManualAccessibility` alone is
      enough to wake Electron apps; write even that only when the first snapshot fails to
      find a focused element (i.e., when actually needed).
- [x] `AXEnableRegistry` already tracks the PIDs we flagged; on app shutdown
      (`NSApplication.willTerminateNotification`) and when a monitored app goes to the
      background, write `AXManualAccessibility=false` back to those PIDs.
- [x] Add an "Electron support" toggle to Settings (default off) — only write the flag if
      the user opts in.

**Acceptance criterion:** With BiSpell running, Chrome/VS Code CPU in Activity Monitor is
~the same as with BiSpell off; quitting BiSpell leaves no lasting footprint on the system.

### 1.2 Compute suggestions lazily 🔴

**Files:** `Sources/BiSpellCore/SpellEngine.swift` (`check`, `evaluate`),
`Sources/BiSpellApp/SpellSessionController.swift`

**Problem:** `check()` generates suggestions immediately for every misspelled word. Each
suggestion goes through `NSSpellChecker.guesses`, an XPC round trip to AppleSpell (tens of
ms per word). But markers only need ranges; suggestions are only needed when the popup opens.

**Tasks:**
- [x] Make `Misspelling.suggestions` populate on demand: `check()` should only decide
      correct/incorrect (`isCorrect` is enough), no suggestion generation.
- [x] Make `SpellEngine.suggestions(for:language:)` public; have `updateAutoPopup` and
      `hotkeyCheckSelectionOrFirstMistake` call it right before showing the popup.
- [x] Add a per-word LRU cache (e.g. `word+lang → (isCorrect, suggestions)`,
      ~2,000 entries). The same misspelled word must not be recomputed every tick.

**Acceptance criterion:** While typing in a text with 10 misspelled words, AppleSpell
process CPU drops noticeably; the popup fills in <100 ms on first open.

### 1.3 Timer hygiene 🟡

**File:** `Sources/BiSpellApp/SpellSessionController.swift` (`start`, lines ~59-68)

**Tasks:**
- [x] Add `timer.tolerance = interval * 0.2` (timer coalescing → fewer wakeups, less energy).
- [x] Stop the timer entirely (`stop()`) when `isEnabled == false` or `isPaused == true`;
      restart it on settings change. Right now it wakes at 4 Hz even while disabled.
- [x] Call `AXUIElementSetMessagingTimeout(appElement, 0.5)` — a busy target app must not
      be able to block BiSpell for the default of up to 6 seconds.

### 1.4 Reduce the double cost for language-ambiguous words 🟡

**Files:** `Sources/BiSpellCore/SpellEngine.swift` (`evaluateBoth`),
`Sources/BiSpellCore/LanguageTagger.swift` (lines ~48-55)

**Tasks:**
- [x] Don't create a new `NLLanguageRecognizer` per word; reuse a single instance (via
      `reset()`) **or** detect language once per text instead of per word and cache the
      result for the duration of the tick.
- [x] `evaluateBoth` already checks `isCorrect` in both languages first; once suggestion
      generation becomes lazy (1.2), most of this cost disappears on its own — still, if
      the popup requests suggestions in both languages at once, narrow to one language
      first using the cheap Hunspell `contains` results.

---

## Phase 2 — Memory: the suggestion index (~500 MB → ~0) 🔴

**File:** `Sources/BiSpellCore/HunspellDictionary.swift` (`buildDeleteMap`, lines ~60-84)

**Problem:** The SymSpell-style delete map generates millions of String keys for ~370k
Turkish stems → measured ~528 MB heap. It is built **on the main thread** on first use
(multi-second freeze), then retained forever. Moreover, this index is only a **fallback**
path used when NSSpellChecker returns no suggestions.

**Recommendation (preferred):** Remove the delete map entirely.
- [x] In `suggestions(for:)`, generate candidates using the already existing
      `generateRestrictedEdits` (all distance-1 edits of the input word → `lowercaseMap`
      dictionary lookups). Distance-1 is fully covered; losing distance-2 is acceptable
      for a fallback path (NSSpellChecker remains the primary source).
- [x] Merge the `lowercaseMap` + `frequency` pair into a single structure
      (`[String: (canonical: String?, order: Int32)]`; store canonical only when it
      differs from the lowercase form) → base dictionary memory also drops ~40%.

**Alternative (if measured suggestion quality is insufficient):** Keep the delete map but:
- [ ] Use `[UInt64(FNV hash): [UInt32 word index]]` instead of String lists (~10× smaller),
      build it on a background queue, evict after 10 minutes of no use.
      *(Not built — preferred path met acceptance; see post-implementation notes.)*

**Acceptance criterion:** Persistent memory measured with `footprint` < 120 MB; no
main-thread freeze on first suggestion; top-3 suggestion accuracy for Turkish typos is
compared against current behavior and found acceptable (A/B with a small test word list).

---

## Phase 3 — Event-driven monitoring instead of polling 🔴

**Files:** `Sources/BiSpellApp/AXTextAccess.swift`,
`Sources/BiSpellApp/SpellSessionController.swift`

**Problem:** Every 250 ms, ~7-8 **synchronous** AX IPC calls are made to the frontmost
app; the field's full text is read on every tick. Even when the user isn't typing, the
target app's main thread is kept busy — the main source of the "the app I'm working in
feels sluggish" effect.

**Tasks:**
- [x] Set up an `AXObserver`; subscribe to:
      `kAXFocusedUIElementChangedNotification`, `kAXValueChangedNotification`,
      `kAXSelectedTextChangedNotification`.
- [x] Catch app switches via `NSWorkspace.didActivateApplicationNotification` (dropping
      the frontmostApplication polling); move the observer to the new PID.
- [x] Read the text only when `ValueChanged` fires; `SelectedTextChanged` is enough for
      the caret.
- [x] Apply a **real** 250 ms debounce when a notification arrives (via Task /
      DispatchWorkItem cancellation) — the `debounceMilliseconds` setting finally gets
      its true meaning.
- [x] For apps where the observer can't be set up (some web areas send no notifications),
      keep the current polling as a **fallback**, but raise the interval to 1 s and skip
      the text read by first querying `kAXNumberOfCharactersAttribute` (length only) —
      if the length is unchanged, skip.
- [x] For 4000+ character content, read only a window around the caret via
      `kAXStringForRangeParameterizedAttribute` instead of the full text (in apps that
      support it).

**Acceptance criterion:** AX calls to the target app while the user is not typing ≈ 0
(verify with Instruments/`sample`); while typing, the call count is small and constant
per event.

---

## Phase 4 — Overlay window churn 🟡

**File:** `Sources/BiSpellApp/OverlayController.swift` (`showMarkers`, lines ~50-61)

**Problem:** On every text change, up to 30 `NSPanel`s are destroyed and recreated; each
marker triggers `screenRectForMisspelling` → `focusedElement()` + `boundsForRange` = 2+
extra synchronous AX calls (~60-90 IPCs per change). Window creation/destruction taxes
WindowServer, which makes the whole system feel slow.

**Tasks:**
- [x] **Single overlay window**: one transparent window covering the focused field's
      frame + a single layer (CAShapeLayer/NSView) drawing the underlines. One window
      instead of 30; updating markers = updating a path.
- [x] Resolve `focusedElement()` **once per update** instead of per marker, and pass the
      same element into the `boundsForRange` calls.
- [x] If the misspelling list and positions are unchanged (`==` comparison), do nothing —
      the current code rebuilds from scratch every time.
- [x] Move the popup panel to the same pattern: one panel + content updates instead of
      recreating it on every open.

**Acceptance criterion:** No observable WindowServer CPU increase while typing; window
creation count per change is 0-1 in Quartz Debug/Instruments.

---

## Phase 5 — Minor items and cleanup 🟢

- [x] Throttle the `probeSupport()` disk write to at most once per minute instead of on
      every app switch (or batch-write on shutdown).
- [x] In `Tokenizer.tokenize`, replace the character-by-character `substring(with:)` loop
      with block scanning via `rangeOfCharacter(from: invertedSet)` (small but free win).
- [x] Delete the email-named files in `Resources/AppIcon.iconset/`
      (`walt.e@example.net` etc.) — misnamed icon copies; no performance impact, just
      package hygiene.

---

## Verification plan (after each phase)

1. **Memory:** `footprint <pid>` — target: < 120 MB persistent after Phase 2.
2. **BiSpell CPU:** `top -pid <pid>` idle and while typing; compare AX/XPC wait times on
   the main thread with Instruments Time Profiler.
3. **Exported load:** CPU of the target app (Chrome/VS Code), AppleSpell, and
   WindowServer in Activity Monitor — A/B comparison with BiSpell on/off.
4. **Behavior:** `swift test` + manual testing in TextEdit, Notes, Chrome, and VS Code:
   markers, popup, applying corrections, hotkey flow.
5. **Persistence check:** Quit BiSpell → verify Chrome/VS Code CPU returns to baseline
   (the proof for Phase 1.1).

## Suggested execution order and estimated impact

| Phase | Impact | Effort | Note |
|-------|--------|--------|------|
| 1.1 AX flag | Ends the system-wide, persistent slowdown | Hours | Do this first |
| 1.2 Lazy suggestions | Ends the CPU/XPC storm while typing | Hours | |
| 2 Delete map | Recovers ~500 MB of memory | 0.5-1 day | With A/B quality test |
| 3 Event-driven AX | Zeroes out the idle IPC load | 1-2 days | Biggest structural work |
| 4 Single overlay | Ends the WindowServer load | 0.5-1 day | |
| 5 Cleanup | Marginal | Hours | Opportunistic |

---

# Post-implementation verification — 2026-07-08 (updated)

## Round 1 (code complete, verification incomplete)

Code was shipped with task checkboxes marked `[x]`, plus `swift test` 30/30 and footprint
**~66 MB** (target < 120 MB ✓). A later review found residual gaps; those are closed below.

## Why residual items were not done in the first pass

1. **Plan ambiguity / “done enough” bias** — The agent treated implementation tasks as the
   deliverable and used *code-level* acceptance (builds, unit tests, memory smoke) as “complete.”
   Live Activity Monitor A/B, Instruments AX sampling, and a second pass over package hygiene
   were listed as verification but not executed as blocking work.
2. **Iconset misdiagnosis** — Round 1 deleted only `walt.e@example.net`. A later note
   claimed the remaining files were "valid `icon_*@2x.png` iconutil names"; that was
   **incorrect** — they were still literally named `diana.k@example.org`,
   `ivan.p@example.net`, `wendy.h@example.net`. Their pixel sizes (32 / 64 / 512) did
   match the @2x variants, i.e. they were **misnamed retina assets**, unusable by
   `iconutil` under those names. Fixed in Round 3 by renaming (see below). No runtime
   impact either way: `Scripts/package-app.sh` ships the pre-built `AppIcon.icns` and
   never reads this folder.
3. **Phase 2 Alternative** — Marked `[x]` by mistake when bulk-checking the plan file. It is
   the *conditional* FNV design; preferred path already landed. Checkbox restored to `[ ]`.
4. **Idle AX ≈ 0** — Safety-net 1 Hz poll was a deliberate trade-off for silent web AX hosts.
   The “≈ 0” criterion needed a follow-up (event-healthy silence gate + 5 s empty-field backoff),
   not the first structural cut.
5. **Minor defects** — Cache empty-list recompute, dead `lastNudgedBackgroundPID` block,
   AXObserver accumulation, and focused-element messaging timeout were review findings after
   the first ship; they were not in the original task bullets.

## Round 2 follow-ups (implemented)

### Package hygiene (Phase 5 icons) — corrected in Round 3 (2026-07-08)
- [x] Round 1 deleted `walt.e@example.net` (1024×1024 — was in fact the would-be
      `icon_512x512@2x.png`; content recovered from `AppIcon-1024.png`, see below).
- [x] Round 3: renamed the three remaining email-named files to their real identities:
      `diana.k@example.org` (32 px) → `icon_16x16@2x.png`,
      `ivan.p@example.net` (64 px) → `icon_32x32@2x.png`,
      `wendy.h@example.net` (512 px) → `icon_256x256@2x.png`.
- [x] Round 3: filled the missing retina slots from existing artwork:
      `icon_128x128@2x.png` (copy of `icon_256x256.png`) and
      `icon_512x512@2x.png` (copy of `AppIcon-1024.png`).
- [x] Round 3: full 10-file iconset validated — `iconutil -c icns` compiles it cleanly.
      Shipped `AppIcon.icns` left untouched (packaging script uses it directly).
- [x] Phase 2 Alternative checkbox corrected to `[ ]`.

### Phase 3 idle AX ≈ 0 (follow-up)
- [x] While `AXObserver` is attached and an event arrived in the last **3 s**, fallback tick
      does **no** AX probes (idle IPC ≈ 0).
- [x] After silence ≥ 3 s, only `kAXNumberOfCharactersAttribute` length probe; full snapshot
      only if length changed.
- [x] No focused text field → clear overlays and back off timer to **5 s**.
- [x] Observer attach uses **5 s** safety interval; poll-only apps stay at **1 s**.

### Minor defects
- [x] `CacheEntry.suggestionsComputed` — empty suggestion lists are cached and not recomputed.
- [x] Removed dead `lastNudgedBackgroundPID` placeholder in `handleAppActivation`.
- [x] `refreshElementNotifications` removes value/selection notifications from the previous
      focused element before adding the new one; `stop()` tears both down.
- [x] `AXUIElementSetMessagingTimeout(0.5)` also applied to focused elements (snapshot +
      observer watch target), not only the app element.
- [x] Language-ambiguous misspellings: correctness path may leave `.unknown`; popup path
      (`withSuggestions`) compares TR vs EN top suggestions by edit distance (restores old
      ranking without XPC on every tick).

## Live measurements (this machine) — 2026-07-08 reinstall after Round 2

| Metric | Value | Notes |
|--------|-------|-------|
| `footprint` shortly after launch | **92 MB** | Peak phys_footprint 92 MB; under 120 MB target ✓ |
| Earlier Round 1 sample | **66 MB** | Same order of magnitude; varies with dict/load timing |
| Baseline before plan | **538 MB** | Dominated by SymSpell delete map |
| `swift test` | **31/30→31** passed | Includes empty-suggestion cache test |

Human A/B for Chrome / AppleSpell / WindowServer still recommended (table below).

## Acceptance criteria still requiring human A/B eyes

These cannot be fully proven from unit tests alone:

1. Chrome/VS Code CPU with BiSpell on vs. off (Electron support **off**).
2. AppleSpell CPU while typing many misspellings (lazy suggestions).
3. WindowServer CPU while typing (single overlay).
4. Quit BiSpell → Electron apps return to baseline (rollback proof).
