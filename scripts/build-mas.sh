#!/bin/sh
# Builds the Mac App Store package: a universal, sandboxed S1Print.app signed
# with "Apple Distribution", wrapped in a .pkg signed with the Mac installer
# certificate, ready for `xcrun altool --upload-app`.
#
#   PROFILE=path/to/S1Print_MAS.provisionprofile scripts/build-mas.sh
set -eu
cd "$(dirname "$0")/.."
: "${PROFILE:?set PROFILE to the Mac App Store provisioning profile}"
APP_ID="${APP_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Distribution[^"]*\)".*/\1/p' | head -1)}"
PKG_ID="${INSTALLER_IDENTITY:-$(security find-identity -v | sed -n 's/.*"\(3rd Party Mac Developer Installer[^"]*\)".*/\1/p' | head -1)}"
[ -n "$APP_ID" ] && [ -n "$PKG_ID" ] || { echo "missing Apple Distribution or Mac installer identity" >&2; exit 1; }

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
APP=build/mas/S1Print.app
rm -rf build/mas
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/s1print" "$APP/Contents/MacOS/s1print"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/printer-icon.png Resources/container-migration.plist "$APP/Contents/Resources/"
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
codesign --force --options runtime --timestamp --sign "$APP_ID" \
  --entitlements Resources/S1Print-AppStore.entitlements "$APP"
codesign --verify --strict --verbose=2 "$APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
PKG="build/mas/S1Print-$VERSION.pkg"
productbuild --component "$APP" /Applications --sign "$PKG_ID" "$PKG"
echo "built $PKG"
