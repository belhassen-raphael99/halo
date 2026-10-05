#!/usr/bin/env bash
# Compile Halo et assemble build/Halo.app (app d'arrière-plan : pas d'icône dans le Dock).
#   ./scripts/build-app.sh            → build/Halo.app
#   ./scripts/build-app.sh --install  → copie aussi dans ~/Applications et relance Halo
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="0.2.1"
APP="build/Halo.app"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Halo "$APP/Contents/MacOS/Halo"
# L'icône de l'app (générée par : .build/release/Halo --appicon Resources/AppIcon.icns).
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Halo</string>
  <key>CFBundleDisplayName</key><string>Halo</string>
  <key>CFBundleIdentifier</key><string>com.belhassen.halo</string>
  <key>CFBundleExecutable</key><string>Halo</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Signature locale (ad hoc) : suffit pour lancer l'app sur ce Mac.
codesign --force --sign - "$APP"
echo "OK → $APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  pkill -x Halo 2>/dev/null || true
  rm -rf "$HOME/Applications/Halo.app"
  cp -R "$APP" "$HOME/Applications/Halo.app"
  open "$HOME/Applications/Halo.app"
  echo "Installé → ~/Applications/Halo.app"
fi
