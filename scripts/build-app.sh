#!/bin/bash
# Builds build/SafariProfileSwitcher.app. Pass --install to copy it to /Applications and (re)launch it.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product SafariProfileSwitcher
BIN="$(swift build -c release --show-bin-path)/SafariProfileSwitcher"

APP=build/SafariProfileSwitcher.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SafariProfileSwitcher"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Localizations compiled from the string catalogs, put where Bundle.main looks for them.
cp -R "$(dirname "$BIN")"/SafariProfileSwitcher_SafariProfileSwitcher.bundle/Contents/Resources/*.lproj "$APP/Contents/Resources/"

# Use a real signing identity if available (see scripts/create-signing-cert.sh): ad-hoc
# signatures change on every build, and macOS then forgets the Accessibility permission.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning \
    | awk -F'"' 'NF > 1 { print $2; exit }')}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed with: ${IDENTITY:-ad-hoc})"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x SafariProfileSwitcher || true
    rm -rf /Applications/SafariProfileSwitcher.app
    cp -R "$APP" /Applications/
    open /Applications/SafariProfileSwitcher.app
    echo "Installed and launched /Applications/SafariProfileSwitcher.app"
fi
