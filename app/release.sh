#!/bin/sh
# release.sh — build a universal (arm64 + x86_64) MusicSign.app and zip it for
# GitHub Releases distribution. No Developer ID / notarization (recipients bypass
# Gatekeeper once via xattr, see release notes).
set -e
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
BIN="$ROOT/bin"
VERSION="0.0.2"
APP="$ROOT/build/MusicSign.app"
ZIP="$ROOT/build/MusicSign-${VERSION}.zip"

rm -rf "$ROOT/build"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 1) universal MediaRemote adapter dylib (arm64 + x86_64), compiled from source
echo ">> building universal dylib"
clang -arch arm64 -arch x86_64 -fobjc-arc -dynamiclib -framework Foundation \
  "$BIN/mr_adapter.m" -o "$APP/Contents/Resources/libmr_adapter.dylib"
codesign -s - --force "$APP/Contents/Resources/libmr_adapter.dylib"

# 2) universal Swift binary (swiftc has no -arch flag; build both targets + lipo)
echo ">> building universal binary"
swiftc -parse-as-library -target arm64-apple-macos14.0 \
  -framework SwiftUI -framework AppKit -framework WebKit -framework ApplicationServices \
  MusicSignApp.swift -o "$APP/Contents/MacOS/MusicSign-arm64"
swiftc -parse-as-library -target x86_64-apple-macos14.0 \
  -framework SwiftUI -framework AppKit -framework WebKit -framework ApplicationServices \
  MusicSignApp.swift -o "$APP/Contents/MacOS/MusicSign-x86_64"
lipo -create "$APP/Contents/MacOS/MusicSign-arm64" "$APP/Contents/MacOS/MusicSign-x86_64" \
  -output "$APP/Contents/MacOS/MusicSign"
rm "$APP/Contents/MacOS/MusicSign-arm64" "$APP/Contents/MacOS/MusicSign-x86_64"

cp Info.plist "$APP/Contents/Info.plist"
cp "$BIN/loader.pl" "$APP/Contents/Resources/loader.pl"

# 3) ad-hoc sign the bundle (stable signature for TCC)
echo ">> signing bundle"
codesign -s - --force --deep "$APP" 2>/dev/null || codesign -s - --force "$APP"

# 4) zip with directory structure preserved
echo ">> zipping"
cd "$ROOT/build"
rm -f "$ZIP"
ditto -c -k --keepParent MusicSign.app "$ZIP"

echo
echo "arch:  $(lipo -archs "$APP/Contents/MacOS/MusicSign")"
echo "size:  $(du -sh "$APP" | cut -f1)"
echo "zip:   $(du -sh "$ZIP" | cut -f1) -> $ZIP"
