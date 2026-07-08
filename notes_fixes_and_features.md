# Notes / Lock / Template — Bug Fixes & New Features

> Date: 2026-07-08 · Scope: Notes editor (lock & template feature) bug fixes from code
> review, plus 3 new features. Hand this file to the implementing agent as the task brief.
>
> **Precondition:** the repo is still NOT a git repository. Run `git init` and make an
> initial commit before starting, so every change here is reviewable and revertable.
>
> After each part: `swift build` and `swift test` must pass; add tests where indicated.

Relevant files:
- `Sources/BiSpellCore/LockedSpan.swift` — span model + `LockedSpanMath`
- `Sources/BiSpellApp/NoteTextEditor.swift` — NSTextView wrapper, edit gating (`shouldChangeTextIn`)
- `Sources/BiSpellApp/NotesViewModel.swift` — `canEdit` / `applyEdit` / lock & template actions
- `Sources/BiSpellApp/NotesRootView.swift` — toolbar, sidebar, menus
- `Sources/BiSpellApp/SpellSessionController.swift` + `AXTextAccess.swift` — system-wide hotkey path
- `Tests/BiSpellCoreTests/LockedSpanTests.swift`

---

# Part A — Bugs found in review

## A1. ⌘Z / Undo is broken in the Notes editor 🔴 (must fix)

**Where:** `NoteTextEditor.swift`, `Coordinator.textView(_:shouldChangeTextIn:replacementString:)`
(~lines 186-220).

**Problem:** When `applyEdit` is provided, the delegate applies every edit manually to
`textStorage` and returns `false`. Returning `false` means NSTextView never registers the
change with its undo manager (even though `allowsUndo = true`). Result: nothing typed or
deleted in the Notes editor can be undone with ⌘Z. This regressed when lock gating was
added; the previous return-`true` path had working undo.

**Fix (pick one, A preferred):**
- **A (preferred):** Return `true` for permitted edits and let NSTextView apply them (undo
  registration happens automatically). Capture the `affectedCharRange` +
  `replacementString` in `shouldChangeTextIn`, then perform the model update + span
  adjustment (`viewModel.applyEdit` logic minus the text mutation) in
  `textDidChange`. Blocked edits still return `false`.
- **B:** Keep manual application but register undo explicitly: before mutating, snapshot
  the replaced substring and the current `draftLockedSpans`; register an inverse operation
  on `textView.undoManager` that restores both text and spans (and a redo that re-applies).

**Important either way:** undo must also restore `lockedSpans` to the state they had
before the edit (spans shift on every edit — reverting text without reverting spans
corrupts lock positions).

**Acceptance criteria:**
1. Type a word in a note → ⌘Z removes it → ⌘⇧Z restores it.
2. Delete text before a locked span → ⌘Z restores it AND the locked highlight is back on
   the correct characters (spans re-shifted correctly).
3. Apply a spelling suggestion → ⌘Z reverts the word.
4. Blocked edits (typing into a lock) still beep and change nothing; ⌘Z after a blocked
   attempt does not corrupt anything.
5. Add a UI-less unit test for the span-restore math if the fix adds any new
   `LockedSpanMath` helper.

## A2. Blocked edits give no visible feedback 🟡

**Where:** `NoteTextEditor.swift` `shouldChangeTextIn` (beep-only branch) and
`NotesViewModel`.

**Problem:** Typing into a locked span only beeps. `applySuggestion` already sets
`saveStatus = "Can't edit locked text"`, but direct typing does not.

**Fix:** In the blocked branch, also notify the view model (add e.g.
`onBlockedEdit: (() -> Void)?` to `NoteTextEditor`) so it can set
`saveStatus = "Can't edit locked text — unlock first"`. Keep the beep.

**Acceptance:** typing inside a locked span shows the status message; the message resets
on the next successful edit.

## A3. `paintLockedSpans` rewrites attributes over the whole text on every keystroke 🟢

**Where:** `NoteTextEditor.swift` `Coordinator.paintLockedSpans()` — called from every
`shouldChangeTextIn` application and every `updateNSView`.

**Problem:** It removes/re-adds `.backgroundColor`, `.foregroundColor`, and `.font`
across the full document each time — O(n) attribute churn per keystroke. Fine for small
notes, wasteful for long ones.

**Fix:** Only repaint when `lockedSpans`, font, or colors actually changed (cache the
last-painted signature), and/or limit attribute work to the edited paragraph range plus
the span ranges.

**Acceptance:** typing in a 10k-word note does not run full-document attribute passes on
every keystroke (verify by logging or profiling); locked highlight still correct after
edits, theme change, and font change.

## A4. "New Template" silently saves a dirty draft; "New Note" asks 🟢

**Where:** `NotesRootView.swift` `attemptNewTemplate()` vs `attemptNewNote()`.

**Problem:** Inconsistent dirty-state handling — `attemptNewNote` shows the
Save/Discard/Cancel alert, `attemptNewTemplate` silently saves.

**Fix:** Route both through the same confirmation flow (reuse `showDirtyNewAlert`, plumb
a flag for `asTemplate`).

**Acceptance:** with unsaved changes, both "New Note" and "New Template" show the same
alert; Cancel leaves everything untouched.

---

# Part B — New features

## B1. "Fix All" hotkey — apply the top suggestion to every mistake in the selection 🔴

System-wide feature (the AX path, not just Notes). The pieces already exist:
`AXTextAccess.snapshot` (selection + text), `SpellEngine.check`,
`engine.withSuggestions`, `AXTextAccess.replaceUTF16Range`.

**Behavior:**
- New global hotkey (suggest **⌥⌘/** to avoid colliding with existing **⌥⌘.**; register in
  `HotkeyManager` alongside the current one, new hotkey ID).
- If the focused field has a selection: spell-check only the selected range; for every
  misspelling that has at least one suggestion, replace it with the top suggestion.
- If there is no selection: fall back to the whole field (respect the existing
  4000-char/windowed-read limits — operate on what `snapshot()` returns).
- **Apply replacements back-to-front** (highest `utf16Range.location` first) so earlier
  ranges stay valid as text shifts. Remember `textUTF16Offset` when mapping ranges
  (windowed snapshots).
- Skip words with no suggestions; count them separately.
- Record each applied fix in `CorrectionLogStore` (wrong → correct), same as Notes does.
- Report the result in `lastSnapshotSummary`, e.g. `"Fixed 7 · skipped 2"`.
- Also add the same action to the Notes editor (toolbar button or ⌥⌘/ while the Notes
  window is focused) using the `applyEdit` path so locks are respected: misspellings
  inside locked spans are already filtered out of `misspellings`; still guard each
  replacement with `canEdit`.

**Acceptance criteria:**
1. In TextEdit, select a paragraph with 5 misspellings → hotkey → all 5 fixed in one
   action, correct words untouched, caret/selection ends in a sane place.
2. Words with no suggestions are left as-is and counted in the summary.
3. Multiple fixes in one pass do not corrupt offsets (fixes applied back-to-front; add a
   core unit test with 3+ misspellings where replacement lengths differ).
4. In Notes: locked-span misspellings are never touched; undo (after A1) reverts the
   whole fix-all as one step in Notes, or at worst word-by-word — document which.
5. Hotkey does nothing (no beep loop, no crash) when there is no readable field.

## B2. Instantiate a template directly — without opening the template first 🟡

**Current gap:** "New Note from This Template" only appears when the template itself is
selected. Creating a note from a template requires selecting the template first (which
also runs the dirty-note guard flow).

**Behavior:**
- In the toolbar **New** menu, add a **"New Note from Template ▸"** submenu listing all
  templates by `displayTitle` (disabled/hidden when there are no templates).
- Choosing one calls `createNoteFromTemplate(id)` directly — regardless of which note is
  currently open. Existing dirty-draft protection applies (`flushPendingSave()` is already
  called inside `createNoteFromTemplate`; verify the dirty alert flow is not bypassed —
  if the current draft is dirty, either auto-save like today or show the standard alert;
  match whatever A4 standardizes on).
- Keep the existing per-row context-menu action as-is.

**Acceptance criteria:**
1. With a regular note open and 2+ templates existing: New ▸ New Note from Template ▸
   pick one → a new regular note appears with the template's body **and locked spans**,
   sidebar selection moves to it.
2. Menu lists templates by title and updates when templates are added/renamed/deleted.
3. Dirty current draft is not silently lost (alert or auto-save per A4 policy).

## B3. Smart delete over mixed selections — delete unlocked text, keep locked text 🔴

**Current gap:** Select-all + Delete does nothing when any locked span is inside the
selection (`blocksEdit` blocks the whole edit). Desired: deleting a selection that mixes
locked and unlocked text deletes **only the unlocked parts** and keeps every locked span
intact.

**Design:**
- Add `LockedSpanMath.unlockedSegments(of range: NSRange, spans: [LockedSpan]) -> [NSRange]`
  — the sub-ranges of `range` not covered by any span (normalized spans make this a
  simple sweep). Unit-test it directly (empty result when fully locked, whole range when
  no overlap, multi-segment cases, adjacent-span edges).
- In the editor gate (`shouldChangeTextIn` / view model): when the edit is a **pure
  deletion** (`replacement.isEmpty`, `range.length > 0`) and the range overlaps locks,
  do NOT reject. Instead delete each unlocked segment **back-to-front** via the existing
  `applyEdit` per segment (each segment individually passes `canEdit`), then place the
  caret at the start of the original selection.
- Scope rule: only pure deletions (Backspace / Delete / Cut) get this treatment.
  **Typing a replacement over a mixed selection stays blocked** (with A2 feedback) —
  replacing "around" locks silently would be surprising.
- Cut (⌘X) should copy the full selection (including locked text — copying locked text is
  allowed by design) and then smart-delete only the unlocked segments.
- Undo (after A1) must restore the deleted segments and span positions.

**Acceptance criteria:**
1. Note: `AAA [LOCKED] BBB` → Select All → Delete → result is `[LOCKED]` only, still
   locked/highlighted at its new position (location shifted to 0).
2. `AAA [L1] BBB [L2] CCC` → Select All → Delete → `[L1][L2]` remain, both spans correct.
3. Selection entirely inside one locked span → Delete still blocked (beep + A2 message).
4. Typing a character while a mixed selection is active → blocked, nothing deleted.
5. ⌘X on a mixed selection → clipboard contains the full selected text; document keeps
   only the locked parts.
6. ⌘Z restores the pre-delete text and lock highlights exactly.
7. New `LockedSpanMath` helper has direct unit tests (see Design).

---

# Definition of done

- `swift build` clean; `swift test` green (38 existing tests + the new ones from A1, B1,
  B3).
- Manual smoke pass in the Notes window: lock/unlock, template create/instantiate,
  fix-all, smart delete, undo/redo after each.
- No regressions to the performance work: no new polling, no suggestion computation
  outside popup/apply paths (fix-all computes suggestions once per word at action time —
  that is fine), no full-text attribute churn per keystroke (A3).
