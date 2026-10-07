#!/bin/bash
# Builds ClipStack.app (Apple silicon + Intel) and packs it for a release:
#   dist/ClipStack.app
#   dist/ClipStack-macOS.dmg   open it, drag ClipStack to Applications (or just open it)
#   dist/ClipStack-macOS.zip
#
#   ./macos/build-app.sh [version]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-$(cat "$ROOT/VERSION")}"
DIST="$ROOT/dist"
APP="$DIST/ClipStack.app"
cd "$ROOT"

echo "==> Building $VERSION for Apple silicon and Intel"
for arch in arm64 x86_64; do
    swift build -c release --triple "$arch-apple-macosx13.0" 2>&1 | grep -E "error|warning:|Compiling|Build complete" | tail -1
done

echo "==> Assembling ClipStack.app"
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create -output "$APP/Contents/MacOS/ClipStack" \
    .build/arm64-apple-macosx/release/clipstack .build/x86_64-apple-macosx/release/clipstack
cp "$ROOT/macos/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>ClipStack</string>
	<key>CFBundleDisplayName</key><string>ClipStack</string>
	<key>CFBundleIdentifier</key><string>io.github.punnawit9285.ClipStack</string>
	<key>CFBundleExecutable</key><string>ClipStack</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$VERSION</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>LSUIElement</key><true/>
	<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSHumanReadableCopyright</key><string>Clipboard history with multi-clip paste.</string>
</dict>
</plist>
PLIST
# No Developer ID here, so the app is signed ad hoc: enough to run on Apple
# silicon, but macOS asks once before opening it (see the README).
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

echo "==> Packing"
rm -f "$DIST/ClipStack-macOS.zip" "$DIST/ClipStack-macOS.dmg"
ditto -c -k --keepParent "$APP" "$DIST/ClipStack-macOS.zip"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "ClipStack" -srcfolder "$STAGE" -ov -format UDZO "$DIST/ClipStack-macOS.dmg"
rm -rf "$STAGE"

lipo -archs "$APP/Contents/MacOS/ClipStack" | sed 's/^/    architectures: /'
ls -lh "$DIST"/ClipStack-macOS.* | awk '{print "    " $5 "  " $9}'
