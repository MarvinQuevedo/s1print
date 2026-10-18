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
codesign --force --sign - "$APP"
echo "built $APP"
