#!/bin/bash
# Builds ChargeCap.app (the menu bar app) from the Swift package. No Xcode needed.
# Usage: scripts/make-app.sh            -> build/app.noindex/ChargeCap.app
#        scripts/make-app.sh --install  -> also copies it to ~/Applications (and restarts it)
# The app only edits config.json and shows the battery; the root daemon (scripts/install.sh) does the work.
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="0.1.0"
APP="build/app.noindex/ChargeCap.app"
IDENTITY="${CHARGECAP_SIGN:-SnapMark Dev}"

swift build -c release --product ChargeCapMenu
BIN="$(swift build -c release --show-bin-path)/ChargeCapMenu"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/ChargeCap"

# App icon: every size macOS asks for, from one 1024 px PNG (sips and iconutil ship with macOS).
[[ -f Resources/AppIcon-1024.png ]] || swift scripts/make-icon.swift Resources/AppIcon-1024.png
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET" "$APP/Contents/Resources"
for size in 16 32 128 256 512; do
  sips -z $size $size Resources/AppIcon-1024.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) Resources/AppIcon-1024.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.kelvin.ChargeCap</string>
  <key>CFBundleName</key><string>ChargeCap</string>
  <key>CFBundleExecutable</key><string>ChargeCap</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign --force --sign "$IDENTITY" "$APP"
else
  echo "warning: \"$IDENTITY\" not found, using an ad-hoc signature" >&2
  codesign --force --sign - "$APP"
fi
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  pkill -x ChargeCap 2>/dev/null || true
  rm -rf "$HOME/Applications/ChargeCap.app"
  cp -R "$APP" "$HOME/Applications/"
  echo "Installed to ~/Applications/ChargeCap.app"
fi
