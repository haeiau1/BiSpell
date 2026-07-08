# BiSpell implementation phases

## Phase 0 — Feasibility / scaffold ✅
- SwiftPM macOS 14+ project
- Models for support matrix (`AppSupportSample`, tiers A/B/C)
- AX permission helpers + frontmost probe (in app menu)
- Tests: support matrix codable, tier docs

## Phase 1 — MVP spell engine ✅
- Bundled Hunspell-format TR + EN dictionaries
- Tokenizer (TR/EN letters), language tagger, spell engine
- User lexicon (add word)
- Menu bar app, debounced AX read, suggestion popup, AX replace
- Tests: typos, mixed TR/EN, lexicon, disable

## Phase 2 — Product polish ✅
- Underline markers (best-effort bounds)
- Ignore / Ignore in App
- App denylist defaults (Terminal, 1Password, …)
- Launch at Login toggle (`SMAppService`)
- Near-caret window for large documents
- Light TR/EN stem rules for inflected forms
- Settings window + support probe log to Application Support

## Phase 3 — Hardening ✅
- Global hotkey ⌥⌘. (selection check / first mistake popup)
- Clipboard replace fallback (optional setting)
- Performance: debounce, skip unchanged text, caret-local check on large fields
- Quiet best-effort when AX cannot read (no noisy UI)

## Phase 4 — Fully functional pass ✅
- App bootstraps at launch via `NSApplicationDelegateAdaptor` (was: only after first menu open)
- Working Settings scene (menu “Settings…” actually opens the window and activates the app)
- Ranged AX replace preferred over full-value patch; verifies field text before replacing
- Chromium/Electron reach: `AXManualAccessibility` / `AXEnhancedUserInterface` nudge per app
- Hotkey ⌥⌘. pressed while popup is visible accepts the top suggestion
- Settings UI: denylist add/remove, personal dictionary & ignored-word management
- Support matrix persisted to disk is loaded back at startup
- Suggestion index built lazily (fast launch, hundreds of MB less RAM for TR)
- Popup panel sized to content; fixed identifier-skip regex in tokenizer

## How to run
```bash
cd ~/BiSpell
swift test
./Scripts/package-app.sh
open dist/BiSpell.app
```
Grant **Accessibility** to BiSpell.
