#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_BUNDLE="/Applications/SpaceBoot.app"

mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$SCRIPT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

swiftc -O \
  "$SCRIPT_DIR/Sources/Models.swift" \
  "$SCRIPT_DIR/Sources/SpaceInspector.swift" \
  "$SCRIPT_DIR/Sources/WindowController.swift" \
  "$SCRIPT_DIR/Sources/ProfileManager.swift" \
  "$SCRIPT_DIR/Sources/AppDelegate.swift" \
  "$SCRIPT_DIR/Sources/main.swift" \
  -o "$APP_BUNDLE/Contents/MacOS/SpaceBoot"

codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1
echo "Built and signed: $APP_BUNDLE"
