#!/bin/bash

# Ensure create-dmg is installed
if ! command -v create-dmg &> /dev/null; then
    echo "create-dmg could not be found. Please install it using 'brew install create-dmg'"
    exit 1
fi

APP_SOURCE="DerivedData/BookmarkSync/Build/Products/Release/BookmarkSync.app"
DEST_DIR="Website/assets"
DMG_NAME="BookmarkSync.dmg"
TARGET_DMG="$DEST_DIR/$DMG_NAME"

if [ ! -d "$APP_SOURCE" ]; then
    echo "Error: App not found at $APP_SOURCE"
    echo "Please build the app in Release mode first."
    exit 1
fi

mkdir -p "$DEST_DIR"
rm -f "$TARGET_DMG"

echo "Building $TARGET_DMG..."

create-dmg \
  --volname "BookmarkSync" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "BookmarkSync.app" 150 190 \
  --hide-extension "BookmarkSync.app" \
  --app-drop-link 450 190 \
  "$TARGET_DMG" \
  "$APP_SOURCE"

echo "Done. DMG created at $TARGET_DMG"
