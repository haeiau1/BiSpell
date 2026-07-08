# BiSpell — Product & Implementation Plan

> Initial design plan (pre-implementation). Recreated in-repo for project documentation.  
> Status: **implemented** through Phases 0–3 (see `docs/PHASES.md` for delivery notes).  
> Project root: `~/BiSpell`

---

## 1. Goal

Build a **macOS menu bar application** that corrects / suggests fixes for **misspelled words in Turkish and English**, not only inside the app, but **while typing in other apps** (Notes, browsers, chat, etc.) — system-wide, best-effort.

**Non-goals (MVP):** grammar/style/tone, cloud models, Mac App Store sandbox, silent auto-correct without confirmation, perfect Chrome contentEditable parity, iOS.

---

## 2. Locked product decisions

| Area | Decision |
|------|----------|
| **UX** | As-you-type **suggestions** (underline markers + popup), not silent auto-correct |
| **Reach** | **System-wide**, best-effort across most apps |
| **Unsupported fields** | Quiet best-effort when Accessibility cannot read; optional hotkey fallback later |
| **Languages** | Turkish + English |
| **Correction scope** | **Spelling only** (no grammar) |
| **Engine / privacy** | **Fully offline / local** |
| **Turkish dictionary** | Bundle Hunspell-format TR (+ EN) from day one |
| **Stack** | **Native Swift / SwiftUI** (+ AppKit for Accessibility & overlays) |
| **OS** | **macOS 14 Sonoma+** |
| **Distribution** | **Personal use only** on the developer’s Mac |

### Interaction refinements (post-MVP polish)

- Auto-show suggestion popup for the misspelling **nearest the caret** (no click required).
- Prefer **macOS `NSSpellChecker`** guesses for suggestion quality; Hunspell lists for membership / fallback.
- User actions: accept suggestion, **Add to Dictionary**, **Ignore**, **Ignore in App**.

---

## 3. Architecture approaches considered

| Approach | Feel | Notes |
|----------|------|--------|
| **A. On-demand (hotkey)** | Select / finish word → correct | Reliable, simpler; not continuous |
| **B. As-you-type overlay** | Underlines / popups near cursor | Best UX; needs Accessibility |
| **C. Keyboard interception** | Rewrite keys as you type | Complex, IME/layout risk (Turkish) |
| **D. Browser extension only** | Web only | Does not cover Notes/Slack natively |

**Chosen:** primarily **B** (as-you-type overlay), with **A**-style hotkey as fallback (**⌥⌘.**).

---

## 4. Target system design

```text
┌─────────────────────────────────────────────────────────┐
│  Menu Bar App (SwiftUI settings + AppKit lifecycle)     │
├─────────────────────────────────────────────────────────┤
│  Focus & Text Observer (Accessibility / AX)             │
│    • focused element, value, selection, word bounds     │
├─────────────────────────────────────────────────────────┤
│  Spell Pipeline (local, debounced)                      │
│    • tokenize → language tag → spellcheck → suggestions │
├─────────────────────────────────────────────────────────┤
│  Overlay Controller (NSPanel / floating windows)        │
│    • markers under words + auto suggestion popup        │
├─────────────────────────────────────────────────────────┤
│  Replacer                                               │
│    • set selection + replace via AX (clipboard fallback)│
└─────────────────────────────────────────────────────────┘
         ▲ permissions: Accessibility (required)
```

### Modules (planned → implemented)

| Module | Responsibility |
|--------|----------------|
| **AppShell** | Menu bar, settings, launch-at-login, permissions onboarding |
| **Accessibility** | Focus tracker, text reader, text replacer |
| **Spell** | Language tagger, tokenizer, Hunspell dicts, system suggestions, user lexicon |
| **Overlay** | Non-activating marker + popup panels |
| **Policy** | App denylist, debounce, secure-field skip |

### Permissions

| Permission | Why | MVP |
|------------|-----|-----|
| **Accessibility** | Read/replace text in other apps, position UI | **Required** |
| Input Monitoring | Keystroke hooks | Not required for core loop |
| Screen Recording | OCR fallback | **No** (privacy) |
| Network | Cloud check | **No** |

### Privacy model

- No network client in MVP.
- No screenshot/OCR path.
- Text stays in-process; personal dictionary stored under Application Support.

---

## 5. Spell pipeline

1. Read focused field text + caret (when available) via Accessibility.
2. Tokenize into words with UTF-16 ranges (TR/EN letters).
3. Optionally recheck near caret only for large documents.
4. Skip: short tokens, URLs/emails-ish, denylist apps, secure fields, user lexicon.
5. Detect language (Turkish orthography / function words / `NLLanguageRecognizer` context).
6. Membership: local Hunspell stems (+ light suffix rules) and/or system checker.
7. Suggestions: prefer **NSSpellChecker**; fallback to ranked local edit-distance candidates.
8. Emit misspellings → update markers + auto-popup for nearest-to-caret issue.
9. On accept → replace word range via AX (clipboard fallback if needed).

---

## 6. Delivery phases

### Phase 0 — Feasibility spike
- Empty menu bar app + Accessibility permission.
- Probe whether `AXValue` is readable in Notes, TextEdit, Safari, Chrome, Slack.
- Produce an **app support matrix** (tiers A / B / C).

### Phase 1 — MVP
- Debounced text read in tier-A apps.
- Hunspell TR + English checker path.
- Suggestion popup + replace when AX allows.
- User dictionary (add word).
- Pause / resume from menu bar.

### Phase 2 — Product polish
- Word-bound underlines where AX provides bounds.
- Ignore once / ignore in this app.
- App denylist UI (or defaults).
- Launch at login.
- Better mixed-language heuristics.
- Near-caret window for large documents.

### Phase 3 — Hardening
- Hotkey fallback for selection / first mistake (**⌥⌘.**).
- Clipboard replace fallback (setting / automatic retry).
- Performance: debounce, skip unchanged text, caret-local checks.
- Quiet best-effort when AX cannot read.

**Implementation rule agreed with user:** implement all phases for real; **run tests after each phase** before advancing.

---

## 7. Success criteria (MVP)

- Type mixed TR/EN in **Notes** (and ideally other tier-A apps).
- See suggestions for real typos within ~300 ms of pausing.
- Accept a fix with a click (and later: auto-popup without requiring underline click).
- Add a proper name to the personal dictionary so it stops flagging.

---

## 8. Risks & mitigations

| Risk | Mitigation |
|------|------------|
| Chrome / Slack poor AX support | Support matrix; silent fail; hotkey fallback |
| Turkish false positives (agglutination) | Stem rules + strong user lexicon + ignore |
| Overlay steals focus | Non-activating `NSPanel` only |
| Replace corrupts field | Prefer ranged AX replace; optional clipboard fallback |
| Battery / CPU | Debounce, caret-local recheck, skip huge pastes until idle |
| Weak local suggestions | Prefer system `NSSpellChecker` guesses |

---

## 9. Project layout (planned)

```text
BiSpell/
  plan.md                 ← this document
  README.md
  Package.swift
  docs/
    PHASES.md             ← phase completion checklist
  Sources/
    BiSpellCore/          ← dictionaries, tokenizer, engine, lexicon
    BiSpellApp/           ← menu bar, AX, overlay, hotkeys, settings
  Tests/
    BiSpellCoreTests/
  Scripts/
    package-app.sh        ← build dist/BiSpell.app
  dist/
    BiSpell.app
```

---

## 10. Build & run (for implementers)

```bash
cd ~/BiSpell
swift test
./Scripts/package-app.sh
open dist/BiSpell.app
```

Grant **System Settings → Privacy & Security → Accessibility** to BiSpell.

---

## 11. Open items from planning (resolved)

| Question | Answer |
|----------|--------|
| Corrections while typing? | As-you-type suggestions |
| Day-one scope? | Most apps system-wide |
| Spell logic location? | Fully offline / local |
| Correction style? | Spelling only |
| Stack? | Native Swift / SwiftUI |
| Distribution? | Personal use only |
| Unsupported app behavior? | Best-effort only |
| Turkish dict strategy? | Bundle Hunspell + TR from day one |
| Minimum macOS? | 14+ |

---

## 12. Related docs

- `README.md` — user-facing overview
- `docs/PHASES.md` — what was delivered per phase

---

*Document recreated from the original planning session for the BiSpell project. Not an automatically generated Xcode artifact.*
