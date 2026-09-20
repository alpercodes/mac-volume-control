#!/bin/bash
# Builds a universal (Apple silicon + Intel) "Volume Control.app" into ./build and a shareable disk image into
# ./releases, named after the version in Resources/Info.plist (other versions' images are kept).
# Pass "install" to also copy it to ~/Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")"

BINARIES=()
for ARCH in arm64 x86_64; do
    ARGS=(-c release --triple "$ARCH-apple-macosx15.0" --scratch-path ".build/$ARCH")
    swift build "${ARGS[@]}"
    BINARIES+=("$(swift build "${ARGS[@]}" --show-bin-path)/VolumeControl")
done

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
APP="build/Volume Control.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create -output "$APP/Contents/MacOS/VolumeControl" "${BINARIES[@]}"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# A build number that always increases, so a copy of the app can tell whether another copy is older.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M)" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

# Disk image with an Applications shortcut: the app inside always has its exact name, so dragging it onto
# Applications replaces an older copy instead of creating "Volume Control 2".
DMG="releases/Volume Control $VERSION.dmg"
STAGE="build/dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE" releases
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Volume Control $VERSION" -srcfolder "$STAGE" -format UDZO -quiet "$DMG"
rm -rf "$STAGE"
echo "Built $APP and $DMG"

if [[ "${1:-}" == "install" ]]; then
    DEST="$HOME/Applications/Volume Control.app"
    pkill -x VolumeControl 2>/dev/null && sleep 1 || true
    mkdir -p "$HOME/Applications"
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    open "$DEST"
    echo "Installed and launched $DEST"
fi
