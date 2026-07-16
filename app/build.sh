#!/bin/sh
# build.sh — compile MusicSignApp.swift into a .app bundle (menu bar app, no dock).
set -e
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
APP="$ROOT/build/MusicSign.app"
rm -rf "$ROOT/build"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -parse-as-library \
  -framework SwiftUI -framework AppKit -framework WebKit -framework ApplicationServices \
  MusicSignApp.swift -o "$APP/Contents/MacOS/MusicSign"

cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/bin/libmr_adapter.dylib" "$APP/Contents/Resources/libmr_adapter.dylib"
cp "$ROOT/bin/loader.pl" "$APP/Contents/Resources/loader.pl"

# ad-hoc sign (TCC needs a stable signature)
codesign -s - --force --deep "$APP" 2>/dev/null || codesign -s - --force "$APP"

echo "built: $APP"
