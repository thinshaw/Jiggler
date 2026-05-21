#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Jiggler"
BUILD_DIR="build"
APP_PATH="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"
TMP_DMG="$BUILD_DIR/$APP_NAME-tmp.dmg"

echo "==> Generating Xcode project..."
xcodegen generate

echo "==> Building $APP_NAME..."
xcodebuild \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  | grep -E "(error:|warning: |BUILD (SUCCEEDED|FAILED))" || true

if [ ! -d "$APP_PATH" ]; then
  echo "Build failed — $APP_PATH not found."
  exit 1
fi

echo "==> Creating DMG..."
rm -f "$DMG_PATH" "$TMP_DMG"

create-dmg \
  --volname "$APP_NAME" \
  --window-pos 200 150 \
  --window-size 540 360 \
  --icon-size 100 \
  --icon "$APP_NAME.app" 160 180 \
  --hide-extension "$APP_NAME.app" \
  --app-drop-link 380 180 \
  --no-internet-enable \
  "$DMG_PATH" \
  "$APP_PATH"

echo ""
echo "Done: $DMG_PATH"
