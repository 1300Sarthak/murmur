#!/bin/zsh
# Builds Murmur.app and installs it to /Applications (or ~/Applications if that isn't writable).
set -euo pipefail
cd "$(dirname "$0")/.."
# Prefer full Xcode when present; Command Line Tools with Swift 5.9+ also work.
[[ -d /Applications/Xcode.app ]] && export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build -c release 2>&1 | grep -v -E '^\s*$' | tail -20
APP=build/Murmur.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Murmur "$APP/Contents/MacOS/Murmur"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Sign with your Apple Development identity if you have one (keeps macOS permissions across rebuilds),
# otherwise ad-hoc. MURMUR_SIGN_IDENTITY overrides.
IDENTITY=${MURMUR_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}')}
codesign --force --options runtime --entitlements Resources/Murmur.entitlements --sign "${IDENTITY:--}" "$APP"
DEST=/Applications
[[ -w $DEST ]] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
pkill -x Murmur 2>/dev/null || true
rm -rf "$DEST/Murmur.app"
cp -R "$APP" "$DEST/Murmur.app"
echo "Installed $DEST/Murmur.app (signed: ${IDENTITY:-ad-hoc})"
