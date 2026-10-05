#!/usr/bin/env bash
# Compile Halo et assemble build/Halo.app (app d'arrière-plan : pas d'icône dans le Dock).
#   ./scripts/build-app.sh            → build/Halo.app
#   ./scripts/build-app.sh --install  → copie aussi dans ~/Applications et relance Halo
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="0.4.3"
APP="build/Halo.app"
# Assemblée et signée hors du dossier du projet : le Bureau peut être synchronisé par iCloud,
# qui pose des attributs étendus (FinderInfo) sur les fichiers ; une signature posée par-dessus
# est jugée invalide, et macOS refuse alors l'autorisation Accessibilité.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
SIGNED="$STAGE/Halo.app"

swift build -c release

APP_FINAL="$APP"
APP="$SIGNED"
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

# Signature : avec le certificat local « Halo Developer » s'il existe (scripts/make-signing-cert.sh),
# pour que macOS garde l'autorisation Accessibilité d'une version à l'autre ; sinon ad hoc.
IDENTITY="Halo Developer"
SIGN_AS="-"
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then SIGN_AS="$IDENTITY"; fi
xattr -cr "$APP"
codesign --force --sign "$SIGN_AS" "$APP"
codesign --verify --strict "$APP"

# Copie dans build/ (sans attributs étendus), pour le zip des releases.
rm -rf "$APP_FINAL"
mkdir -p "$(dirname "$APP_FINAL")"
ditto --norsrc --noextattr "$APP" "$APP_FINAL"
echo "OK → $APP_FINAL"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  pkill -x Halo 2>/dev/null || true
  rm -rf "$HOME/Applications/Halo.app"
  ditto --norsrc --noextattr "$SIGNED" "$HOME/Applications/Halo.app"
  xattr -cr "$HOME/Applications/Halo.app"
  codesign --verify --strict "$HOME/Applications/Halo.app"
  open "$HOME/Applications/Halo.app"
  echo "Installé → ~/Applications/Halo.app"
fi
