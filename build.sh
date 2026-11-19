#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_BUNDLE="/Applications/SpaceBoot.app"

mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$SCRIPT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

swiftc -O \
  "$SCRIPT_DIR/Sources/Logger.swift" \
  "$SCRIPT_DIR/Sources/Models.swift" \
  "$SCRIPT_DIR/Sources/SymbolicHotKeys.swift" \
  "$SCRIPT_DIR/Sources/HotKeyManager.swift" \
  "$SCRIPT_DIR/Sources/HotkeyOrderStore.swift" \
  "$SCRIPT_DIR/Sources/AppLauncher.swift" \
  "$SCRIPT_DIR/Sources/SpaceInspector.swift" \
  "$SCRIPT_DIR/Sources/WindowController.swift" \
  "$SCRIPT_DIR/Sources/ProfileManager.swift" \
  "$SCRIPT_DIR/Sources/AppDelegate.swift" \
  "$SCRIPT_DIR/Sources/main.swift" \
  -o "$APP_BUNDLE/Contents/MacOS/SpaceBoot"

# Prefer a persistent Apple Development signing identity (keeps macOS Accessibility TCC across rebuilds),
# falling back to ad-hoc signing for environments without a developer certificate.
SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development:/{print $2; exit}' || true)"
if [[ -n "$SIGN_ID" ]]; then
  codesign --force --deep --sign "$SIGN_ID" "$APP_BUNDLE" >/dev/null 2>&1
  echo "Built and signed ($SIGN_ID): $APP_BUNDLE"
else
  codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1
  echo "Built and ad-hoc signed: $APP_BUNDLE"
fi
