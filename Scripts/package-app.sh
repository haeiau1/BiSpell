#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "→ Building release (uses your current source)…"
swift build -c release

BIN_DIR="$(swift build -c release --show-bin-path)"
BIN="$BIN_DIR/BiSpell"
APP="$ROOT/dist/BiSpell.app"
ICON_ICNS="$ROOT/Resources/AppIcon.icns"

if [[ ! -f "$ICON_ICNS" ]]; then
  echo "Missing $ICON_ICNS — generate Resources/AppIcon.icns first." >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# SPM resource bundles (dictionaries)
for bundle in "$BIN_DIR"/*.bundle(N); do
  echo "  copying $(basename "$bundle")"
  cp -R "$bundle" "$APP/Contents/MacOS/"
  cp -R "$bundle" "$APP/Contents/Resources/"
done

# App icon
cp "$ICON_ICNS" "$APP/Contents/Resources/AppIcon.icns"
# Also keep a PNG for Finder previews / docs
if [[ -f "$ROOT/Resources/AppIcon-1024.png" ]]; then
  cp "$ROOT/Resources/AppIcon-1024.png" "$APP/Contents/Resources/AppIcon.png"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>BiSpell</string>
  <key>CFBundleExecutable</key>
  <string>BiSpell</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>com.hayret.BiSpell</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>BiSpell</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.3.6</string>
  <key>CFBundleVersion</key>
  <string>10</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <false/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © Hayret. Personal use.</string>
</dict>
</plist>
PLIST

cp "$BIN" "$APP/Contents/MacOS/BiSpell"
chmod +x "$APP/Contents/MacOS/BiSpell"

# Ad-hoc sign (personal use)
codesign --force --deep --sign - "$APP" 2>/dev/null || true

# Refresh Finder icon cache for this bundle
touch "$APP"

echo "→ Built $APP"

# Install to /Applications for double-click launch (no terminal)
INSTALL_APP="/Applications/BiSpell.app"
echo "→ Installing to $INSTALL_APP"
# Quit running instance if any (by path / name)
osascript -e 'tell application "System Events" to set procs to (name of every process whose name is "BiSpell")' 2>/dev/null || true
pkill -x BiSpell 2>/dev/null || true
sleep 0.3
rm -rf "$INSTALL_APP"
cp -R "$APP" "$INSTALL_APP"
# Clear quarantine if present so Gatekeeper is less annoying for personal build
xattr -dr com.apple.quarantine "$INSTALL_APP" 2>/dev/null || true
codesign --force --deep --sign - "$INSTALL_APP" 2>/dev/null || true

echo "→ Done."
echo "  Project copy: $APP"
echo "  Open from:    $INSTALL_APP  (Finder → Applications → BiSpell)"
echo "  Or double-click the app. Menu bar only (no Dock icon)."
