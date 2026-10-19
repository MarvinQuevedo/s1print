#!/bin/sh
# Builds, signs with Developer ID, notarizes, staples and zips S1Print for release.
#
# One-time setup, after joining the Apple Developer Program:
#   1. Create a "Developer ID Application" certificate (Xcode → Settings →
#      Accounts → Manage Certificates → + → Developer ID Application).
#   2. Store notary credentials in the keychain (app-specific password from
#      appleid.apple.com, team id from developer.apple.com):
#        xcrun notarytool store-credentials s1print-notary \
#          --apple-id "<your Apple ID>" --team-id "<TEAMID>" --password "<app-specific password>"
#
# Then:  scripts/release.sh            (picks your Developer ID identity)
#   or:  SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/release.sh
set -eu
cd "$(dirname "$0")/.."

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application[^"]*\)".*/\1/p' | head -1)}"
PROFILE="${NOTARY_PROFILE:-s1print-notary}"
[ -n "$IDENTITY" ] || { echo "No 'Developer ID Application' identity found; see the setup notes at the top of this script." >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
SIGN_IDENTITY="$IDENTITY" ./scripts/bundle.sh
APP=build/S1Print.app

# Notarization requires the hardened runtime and a secure timestamp.
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

ZIP="build/S1Print-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"

# Re-zip so the download carries the stapled ticket and opens offline too.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP"
echo "Notarized $ZIP. Publish with: gh release create v$VERSION $ZIP"
