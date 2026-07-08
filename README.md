# BiSpell

Offline Turkish + English spell-check assistant for macOS 14+.

Menu bar app that watches the focused text field (Accessibility), underlines misspellings, and offers local Hunspell-dictionary suggestions.

## Features

- **As-you-type suggestions** (markers + popup)
- **System-wide best-effort** via Accessibility
- **Fully offline** Hunspell word lists (TR + EN)
- **Spelling only** (no grammar)
- Personal dictionary / ignore / ignore-in-app
- App denylist (Terminal, 1Password, …)
- Launch at login
- Hotkey **⌥⌘.** — check selection or jump to first mistake; press again to accept the top suggestion
- Optional clipboard replace fallback
- Settings window: denylist editor, personal dictionary & ignored-word management

## Build & run

```bash
cd ~/BiSpell
swift build -c release
swift test

# Run (dev)
swift run BiSpell
```

Package as `.app` (recommended for Accessibility + Launch at Login):

```bash
./Scripts/package-app.sh
open dist/BiSpell.app
```

Grant **Privacy & Security → Accessibility** to BiSpell when prompted.

## Tests

```bash
swift test
```

## Support matrix

While running, use **Probe Frontmost App Support** from the menu. Results are saved to:

`~/Library/Application Support/BiSpell/support-matrix.json`

## License

Personal use. Dictionaries from [wooorm/dictionaries](https://github.com/wooorm/dictionaries) (respective dictionary licenses).

## Documentation

- [`plan.md`](plan.md) — original product & architecture plan (also at `docs/plan.md`)
- [`docs/PHASES.md`](docs/PHASES.md) — phase delivery checklist

## Notes

BiSpell includes a **plain-text notes** window (sidebar list + editor):

- Open from the Dock / app launch, or menu bar **Open Notes**
- **Manual Save** (toolbar or **⌘S**) to `~/Library/Application Support/BiSpell/Notes/`
- Search, create, delete notes
- After you finish a word (space/punct), a **popup appears near the typo** with suggestions
- **⌘1** = best fix, **⌘2–⌘5** = other choices (works while typing; Esc dismisses)
- **⌥⌘.** still opens suggestions at the caret if needed
- System-wide spell-check in other apps still uses menu bar / **⌥⌘.** when Notes is not focused

Shortcuts: **⌘N** new note, **⌘S** save.

## Learned corrections

When you accept a spelling fix **in the Notes window**, BiSpell appends to:

`~/Library/Application Support/BiSpell/corrections.json`

Each entry is `{ wrong, correct, count, firstCorrectedAt, lastCorrectedAt }`. Counts rise when you repeat the same fix — useful later for a personal most-common-misspellings dictionary.

## Lock & templates

- **Lock selection** (toolbar): selected text becomes read-only but still **selectable/copyable** (highlighted).
- **Unlock**: selection or caret inside a locked span.
- Sidebar **Templates** section is separate from **Notes**.
- **New → New Template**, or **Move to Templates** on a note.
- **New Note from Template** (context menu / menu) copies body + locked spans into a new editable note.

