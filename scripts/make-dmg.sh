#!/bin/sh
# Packs Panes.app into a drag-to-Applications disk image.
#   scripts/make-dmg.sh [app] [dmg]
#   defaults: ~/Library/Caches/Panes/dist/Panes.app -> ~/Library/Caches/Panes/dist/Panes.dmg
# Run scripts/build-app.sh first. The image is signed when SIGN_IDENTITY is set; notarization is
# a separate step (see .github/workflows/release.yml).
set -eu

CACHE="$HOME/Library/Caches/Panes"
APP="${1:-$CACHE/dist/Panes.app}"
DMG="${2:-$CACHE/dist/Panes.dmg}"
STAGE="$CACHE/dmg"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Panes.app"
ln -s /Applications "$STAGE/Applications"

# hdiutil now and then fails with "Resource busy" on CI runners, so retry a few times.
for attempt in 1 2 3 4 5; do
    hdiutil create -volname Panes -srcfolder "$STAGE" -format UDZO -ov "$DMG" && break
    [ "$attempt" = 5 ] && exit 1
    sleep 5
done
rm -rf "$STAGE"

if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi
echo "Built $DMG"
