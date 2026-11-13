#!/bin/bash
# Buduje MacZilla.app. Działa z samym Command Line Tools (bez zaakceptowanej licencji Xcode).
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
PLUGIN=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib
FLAGS=()
[ -f "$PLUGIN" ] && FLAGS=(-Xswiftc -load-plugin-library -Xswiftc "$PLUGIN")

CONFIG="${1:-debug}"
swift build -c "$CONFIG" "${FLAGS[@]}"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/MacZilla"

APP=build/MacZilla.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacZilla"
cp Resources/Info.plist "$APP/Contents/Info.plist"
for L in Resources/*.lproj; do cp -R "$L" "$APP/Contents/Resources/"; done

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
APP_BIN=bin/MacZilla.app
rm -rf "$APP_BIN"
mkdir -p "$(dirname "$APP_BIN")"
ditto "$APP" "$APP_BIN"
echo "OK: $APP"
echo "OK: $APP_BIN"
