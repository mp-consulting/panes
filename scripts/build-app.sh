#!/bin/sh
# Builds Panes.app (arm64, release) and optionally installs it.
#   scripts/build-app.sh            -> ~/Library/Caches/Panes/dist/Panes.app
#   scripts/build-app.sh --install  -> also copies it to ~/Applications and relaunches it
# Build output lives outside the repo: iCloud Drive tags files in Documents with Finder
# metadata, which codesign refuses ("resource fork, Finder information, or similar detritus").
# Signing: SIGN_IDENTITY, else the local "Panes Local Signing" certificate if the keychain has it,
# else an ad-hoc signature ("-"). Ad-hoc ties the Accessibility grant to the build's hash, so
# every rebuild would ask for access again; a certificate keeps one grant across rebuilds.
# A "Developer ID" identity also gets a secure timestamp, which notarization requires.
# VERSION and BUILD_NUMBER, when set, stamp the bundle's version (the release workflow sets them).
set -eu
cd "$(dirname "$0")/.."

CACHE="$HOME/Library/Caches/Panes"
BUILD="$CACHE/build"
APP="$CACHE/dist/Panes.app"

swift build -c release --arch arm64 --scratch-path "$BUILD"
BIN="$(swift build -c release --arch arm64 --scratch-path "$BUILD" --show-bin-path)/Panes"

[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift Resources/AppIcon.icns

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ditto --norsrc --noextattr "$BIN" "$APP/Contents/MacOS/Panes"
ditto --norsrc --noextattr Resources/Info.plist "$APP/Contents/Info.plist"
ditto --norsrc --noextattr Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [ -n "${VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER:-$VERSION}" "$APP/Contents/Info.plist"
fi
xattr -cr "$APP"
if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$(security find-certificate -c "Panes Local Signing" -Z 2>/dev/null | awk '/SHA-1/ {print $3}')"
fi
case "${SIGN_IDENTITY:-}" in "Developer ID"*) TIMESTAMP=--timestamp ;; *) TIMESTAMP= ;; esac
codesign --force --options runtime $TIMESTAMP --sign "${SIGN_IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Panes"), signed by ${SIGN_IDENTITY:--})"

if [ "${1:-}" = "--install" ]; then
    DEST="$HOME/Applications/Panes.app"
    pkill -x Panes 2>/dev/null && sleep 1 || true
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    open "$DEST"
    echo "Installed and launched $DEST"
fi
