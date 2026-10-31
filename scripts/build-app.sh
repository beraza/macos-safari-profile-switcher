#!/bin/bash
# Builds build/SafariProfileSwitcher.app.
#   --install    copy it to /Applications and (re)launch it
#   --self-test  include `--self-test` (left out of the release app otherwise)
set -euo pipefail
cd "$(dirname "$0")/.."

INSTALL=0
SWIFT_FLAGS=()
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        --self-test) SWIFT_FLAGS+=(-Xswiftc -DSELF_TEST) ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

swift build -c release --product SafariProfileSwitcher ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"}
BIN="$(swift build -c release --show-bin-path)/SafariProfileSwitcher"

APP=build/SafariProfileSwitcher.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SafariProfileSwitcher"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Localizations compiled from the string catalogs, put where Bundle.main looks for them.
cp -R "$(dirname "$BIN")"/SafariProfileSwitcher_SafariProfileSwitcher.bundle/Contents/Resources/*.lproj "$APP/Contents/Resources/"

# Version from the VERSION file, build number from the commit count.
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" \
    "$APP/Contents/Info.plist"

# Sign with the local certificate from scripts/create-signing-cert.sh (or $CODESIGN_IDENTITY, e.g. a
# "Developer ID Application: …" identity for distribution). Ad-hoc signatures change on every build,
# and macOS then forgets the Accessibility permission.
IDENTITY="${CODESIGN_IDENTITY:-SafariProfileSwitcher Local Signing}"
if ! security find-identity -v -p codesigning | grep -qF "\"$IDENTITY\""; then
    if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
        echo "Signing identity \"$IDENTITY\" not found" >&2
        exit 1
    fi
    IDENTITY=-
fi
codesign --force --options runtime --timestamp=none \
    --entitlements Resources/SafariProfileSwitcher.entitlements --sign "$IDENTITY" "$APP"
echo "Built $APP $VERSION ($BUILD), signed with: $([[ "$IDENTITY" == - ]] && echo ad-hoc || echo "$IDENTITY")"

if [[ $INSTALL == 1 ]]; then
    pkill -x SafariProfileSwitcher || true
    rm -rf /Applications/SafariProfileSwitcher.app
    cp -R "$APP" /Applications/
    open /Applications/SafariProfileSwitcher.app
    echo "Installed and launched /Applications/SafariProfileSwitcher.app"
fi
