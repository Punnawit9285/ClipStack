#!/bin/bash
# Builds every download for a GitHub release into dist/. Run it on a Mac with
# the .NET SDK installed, since the Mac app can only be built on a Mac.
#
#   ./release.sh [version]
#
#   ClipStack-macOS.dmg, ClipStack-macOS.zip   the Mac app (macos/build-app.sh)
#   ClipStack.exe                              the Windows app (windows/build-exe.sh)
#   ClipStack-Windows-PowerShell.zip           the script version for Windows
#   ClipStack.shortcut                         the iPhone and iPad shortcut
#   ClipStack-iOS-Shortcuts.zip                it, plus the single-purpose shortcuts
#
# The shortcuts are packed as signed in ios/. After changing
# ios/make-shortcuts.py, run it first to sign them again (that needs iCloud).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="${1:-$(cat "$ROOT/VERSION")}"
DIST="$ROOT/dist"
cd "$ROOT"

if [ ! -f ios/ClipStack.shortcut ]; then
    echo "ios/ClipStack.shortcut isn't signed yet. Run: python3 ios/make-shortcuts.py" >&2
    exit 1
fi

./macos/build-app.sh "$VERSION"
echo "==> Building ClipStack.exe $VERSION"
./windows/build-exe.sh "$VERSION"

echo "==> Packing the shortcuts and the PowerShell version"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir "$STAGE/ClipStack iOS Shortcuts" "$STAGE/ClipStack-Windows-PowerShell"
for f in ios/*.shortcut; do
    [[ "$f" == *.unsigned.shortcut ]] || cp "$f" "$STAGE/ClipStack iOS Shortcuts/"
done
cp windows/ClipStack.ps1 windows/*.cmd "$STAGE/ClipStack-Windows-PowerShell/"
rm -f "$DIST/ClipStack-iOS-Shortcuts.zip" "$DIST/ClipStack-Windows-PowerShell.zip"
(cd "$STAGE" && zip -qrX "$DIST/ClipStack-iOS-Shortcuts.zip" "ClipStack iOS Shortcuts" \
             && zip -qrX "$DIST/ClipStack-Windows-PowerShell.zip" ClipStack-Windows-PowerShell)
cp ios/ClipStack.shortcut "$DIST/"

ASSETS=(ClipStack-macOS.dmg ClipStack-macOS.zip ClipStack.exe ClipStack-Windows-PowerShell.zip
        ClipStack.shortcut ClipStack-iOS-Shortcuts.zip)
for a in "${ASSETS[@]}"; do ls -lh "$DIST/$a" | awk '{print "    " $5 "  " $9}'; done
echo
echo "To publish them:"
echo "    cd dist && gh release create v$VERSION --title \"ClipStack $VERSION\" ${ASSETS[*]}"
