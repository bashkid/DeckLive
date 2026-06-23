#!/bin/bash
# Wraps dist/DeckLive.app in a distributable .dmg using hdiutil. Layout
# is the macOS-standard "drag your app to Applications" — a symlink to
# /Applications sits next to the .app inside the disk image.
#
# Output: dist/DeckLive-<version>.dmg

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
cd "$ROOT_DIR"

APP_NAME="DeckLive"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "ERROR: $APP_BUNDLE not found. Run scripts/build-app.sh first."
  exit 1
fi

# Pull the version straight off the .app's Info.plist so the DMG name
# stays in sync with whatever build-app.sh set.
APP_VERSION="$(plutil -extract CFBundleShortVersionString raw \
                 "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || echo "1.0.0")"
DMG_PATH="$DIST_DIR/$APP_NAME-$APP_VERSION.dmg"
STAGE_DIR="$(mktemp -d)/dmg-stage"

echo "==> Staging DMG contents…"
mkdir -p "$STAGE_DIR"
cp -R "$APP_BUNDLE" "$STAGE_DIR/"
# Drag-to-install affordance.
ln -s /Applications "$STAGE_DIR/Applications"

echo "==> Creating $DMG_PATH …"
rm -f "$DMG_PATH"
hdiutil create \
  -volname "$APP_NAME $APP_VERSION" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  -fs HFS+ \
  -imagekey zlib-level=9 \
  "$DMG_PATH" >/dev/null

rm -rf "$(dirname "$STAGE_DIR")"

echo
echo "Done. DMG written to:"
echo "  $DMG_PATH"
echo
echo "Size: $(du -h "$DMG_PATH" | cut -f1)"
echo
echo "Distribute by sharing the .dmg. Recipient double-clicks to mount,"
echo "drags $APP_NAME to Applications, and ejects."
