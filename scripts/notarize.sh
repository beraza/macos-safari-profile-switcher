#!/bin/bash
# Signs build/SafariProfileSwitcher.app with a Developer ID, notarizes and staples it, and zips it for
# distribution. Needs a paid Apple Developer account. Once, store the notary credentials:
#   xcrun notarytool store-credentials SafariProfileSwitcher --apple-id … --team-id … --password <app-specific>
# Then: CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/notarize.sh
set -euo pipefail
cd "$(dirname "$0")/.."

: "${CODESIGN_IDENTITY:?Set CODESIGN_IDENTITY to your \"Developer ID Application: …\" identity}"
PROFILE="${NOTARY_PROFILE:-SafariProfileSwitcher}"
APP=build/SafariProfileSwitcher.app

scripts/build-app.sh
# Notarization needs a secure timestamp, which build-app.sh skips for quick local builds.
codesign --force --options runtime --timestamp \
    --entitlements Resources/SafariProfileSwitcher.entitlements --sign "$CODESIGN_IDENTITY" "$APP"

VERSION="$(tr -d '[:space:]' < VERSION)"
ZIP="build/SafariProfileSwitcher-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Notarized: $ZIP"
