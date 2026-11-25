#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_NAME="SpaceBoot"
CONFIGURATION="release"
ARCH="host"
OUTPUT_DIR="$REPO_ROOT/build"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
SIGN_MODE="${CODESIGN_IDENTITY:-auto}"
VERSION_OVERRIDE=""
BUILD_NUMBER_OVERRIDE=""
DO_INSTALL=false
DO_PACKAGE=false

usage() {
  cat <<'EOF'
Usage: scripts/build.sh [options]

Build, sign, install, or package SpaceBoot.app using Swift Package Manager.

Options:
  -c, --configuration <debug|release>   Build configuration (default: release)
  -a, --arch <host|arm64|x86_64|universal>
                                        Target architecture (default: host)
  -s, --sign <identity|auto|-|none>     Code-signing identity (default: $CODESIGN_IDENTITY or auto)
                                          auto: use an Apple Development cert if available, else ad-hoc (-)
                                          -:    ad-hoc sign (useful for CI and local testing)
                                          none: skip code signing
  -o, --output <dir>                    Output directory for .app and archives (default: ./build)
  --version <semver>                    Override CFBundleShortVersionString in built bundle
  --build-number <number>               Override CFBundleVersion in built bundle
  --install                             Copy SpaceBoot.app into $INSTALL_DIR (default: /Applications)
  --package                             Create a distributable .zip archive and .sha256 checksum
  -h, --help                            Show this help message

Environment variables:
  CODESIGN_IDENTITY                     Default value for --sign
  INSTALL_DIR                           Target directory for --install (default: /Applications)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--configuration)
      CONFIGURATION="$2"
      shift 2
      ;;
    -a|--arch)
      ARCH="$2"
      shift 2
      ;;
    -s|--sign)
      SIGN_MODE="$2"
      shift 2
      ;;
    -o|--output)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --version)
      VERSION_OVERRIDE="$2"
      shift 2
      ;;
    --build-number)
      BUILD_NUMBER_OVERRIDE="$2"
      shift 2
      ;;
    --install)
      DO_INSTALL=true
      shift
      ;;
    --package)
      DO_PACKAGE=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

case "$CONFIGURATION" in
  debug|release) ;;
  *)
    echo "error: --configuration must be 'debug' or 'release' (got '$CONFIGURATION')" >&2
    exit 1
    ;;
esac

case "$ARCH" in
  host|arm64|x86_64|universal) ;;
  *)
    echo "error: --arch must be one of host, arm64, x86_64, universal (got '$ARCH')" >&2
    exit 1
    ;;
esac

INFO_PLIST_SRC="$REPO_ROOT/Resources/Info.plist"
ICON_SRC="$REPO_ROOT/Resources/AppIcon.icns"

if [[ ! -f "$INFO_PLIST_SRC" ]]; then
  echo "error: missing $INFO_PLIST_SRC" >&2
  exit 1
fi

if [[ ! -f "$ICON_SRC" ]]; then
  echo "Resources/AppIcon.icns not found; generating icon..."
  swift "$SCRIPT_DIR/generate-icon.swift"
fi

echo "==> Building $APP_NAME ($CONFIGURATION, arch=$ARCH)..."

cd "$REPO_ROOT"

if [[ "$ARCH" == "universal" ]]; then
  swift build -c "$CONFIGURATION" --arch arm64 --arch x86_64
  BIN_PATH="$(swift build -c "$CONFIGURATION" --arch arm64 --arch x86_64 --show-bin-path)/$APP_NAME"
elif [[ "$ARCH" == "host" ]]; then
  swift build -c "$CONFIGURATION"
  BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)/$APP_NAME"
else
  swift build -c "$CONFIGURATION" --arch "$ARCH"
  BIN_PATH="$(swift build -c "$CONFIGURATION" --arch "$ARCH" --show-bin-path)/$APP_NAME"
fi

if [[ ! -f "$BIN_PATH" ]]; then
  echo "error: expected binary not found at $BIN_PATH" >&2
  exit 1
fi

APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$INFO_PLIST_SRC" "$APP_BUNDLE/Contents/Info.plist"
cp "$ICON_SRC" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

if [[ -n "$VERSION_OVERRIDE" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION_OVERRIDE" "$APP_BUNDLE/Contents/Info.plist"
fi
if [[ -n "$BUILD_NUMBER_OVERRIDE" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER_OVERRIDE" "$APP_BUNDLE/Contents/Info.plist"
fi

APP_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_BUNDLE/Contents/Info.plist")"

# Resolve code signing identity.
# Keeping a consistent local Apple Development identity preserves macOS Accessibility TCC
# across rebuilds; CI and users without a signing certificate fall back cleanly to ad-hoc (-).
resolve_signing_identity() {
  case "$SIGN_MODE" in
    none)
      echo ""
      ;;
    auto)
      local dev_id
      dev_id="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development:/{print $2; exit}' || true)"
      if [[ -n "$dev_id" ]]; then
        echo "$dev_id"
      else
        echo "-"
      fi
      ;;
    *)
      echo "$SIGN_MODE"
      ;;
  esac
}

RESOLVED_SIGN_ID="$(resolve_signing_identity)"

if [[ -n "$RESOLVED_SIGN_ID" ]]; then
  SIGN_ARGS=(--force --deep --sign "$RESOLVED_SIGN_ID")
  if [[ "$RESOLVED_SIGN_ID" == Developer\ ID\ Application:* ]]; then
    SIGN_ARGS+=(--options runtime --timestamp)
  fi

  codesign "${SIGN_ARGS[@]}" "$APP_BUNDLE"
  codesign --verify --deep --strict "$APP_BUNDLE"

  if [[ "$RESOLVED_SIGN_ID" == "-" ]]; then
    echo "==> Signed (ad-hoc): $APP_BUNDLE"
  else
    echo "==> Signed ($RESOLVED_SIGN_ID): $APP_BUNDLE"
  fi
else
  echo "==> Built unsigned: $APP_BUNDLE"
fi

if [[ "$DO_INSTALL" == true ]]; then
  mkdir -p "$INSTALL_DIR"
  INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"
  rm -rf "$INSTALLED_APP"
  ditto "$APP_BUNDLE" "$INSTALLED_APP"

  LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$INSTALLED_APP" >/dev/null 2>&1 || true
  fi
  echo "==> Installed: $INSTALLED_APP"
fi

if [[ "$DO_PACKAGE" == true ]]; then
  ARCHIVE_ARCH="$ARCH"
  if [[ "$ARCHIVE_ARCH" == "host" ]]; then
    ARCHIVE_ARCH="$(uname -m)"
  fi
  ARCHIVE_NAME="${APP_NAME}-${APP_VERSION}-${ARCHIVE_ARCH}.zip"
  ARCHIVE_PATH="$OUTPUT_DIR/$ARCHIVE_NAME"
  CHECKSUM_PATH="$ARCHIVE_PATH.sha256"

  rm -f "$ARCHIVE_PATH" "$CHECKSUM_PATH"
  ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ARCHIVE_PATH"
  (cd "$OUTPUT_DIR" && shasum -a 256 "$ARCHIVE_NAME" > "$(basename "$CHECKSUM_PATH")")

  echo "==> Packaged: $ARCHIVE_PATH"
  echo "==> Checksum: $CHECKSUM_PATH"
fi
