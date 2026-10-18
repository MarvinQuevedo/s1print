#!/bin/sh
# Builds S1Print.app (release) into ./build and signs it ad hoc.
set -eu
cd "$(dirname "$0")/.."
swift build -c release
APP=build/S1Print.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/s1print "$APP/Contents/MacOS/s1print"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/printer-icon.png ] && cp Resources/printer-icon.png "$APP/Contents/Resources/"
# A stable signing identity keeps the Bluetooth permission across rebuilds:
# macOS ties the permission to the code signature, and an ad-hoc signature
# changes with every build, so macOS would ask again after each one.
# Set SIGN_IDENTITY to choose; by default the first "Apple Development"
# identity is used, falling back to ad hoc.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "signed with: ${IDENTITY:-ad hoc (the Bluetooth permission is asked again after each rebuild)}"
echo "built $APP"
