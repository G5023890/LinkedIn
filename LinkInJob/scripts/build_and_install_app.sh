#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

APP_DISPLAY_NAME="${APP_DISPLAY_NAME:-LinkInJob}"
EXECUTABLE_NAME="${EXECUTABLE_NAME:-LinkInJob}"
BUNDLE_ID="${BUNDLE_ID:-com.grigorym.LinkInJob}"
APP_VERSION="${APP_VERSION:-0.9.3}"
BUILD_VERSION="${BUILD_VERSION:-0.9.3}"
APP_DIR="${APP_DIR:-dist/${APP_DISPLAY_NAME}.app}"
INSTALL_DIR="${INSTALL_DIR:-/Applications/${APP_DISPLAY_NAME}.app}"
LEGACY_INSTALL_DIR="${LEGACY_INSTALL_DIR:-/Applications/SelectedTextOverlay.app}"
ICON_SOURCE="${ICON_SOURCE:-$PROJECT_DIR/../assets/LinkedIn.icns}"
SKIP_SIGN="${SKIP_SIGN:-0}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
RESOLVED_SIGN_IDENTITY=""
STAGING_ROOT=""
APP_STAGE=""

log() {
  echo "[build] $*"
}

pick_icon_source() {
  if [[ -n "$ICON_SOURCE" && -f "$ICON_SOURCE" ]]; then
    echo "$ICON_SOURCE"
    return 0
  fi

  local candidates=(
    "$PROJECT_DIR/AppIcon.icns"
    "$PROJECT_DIR/assets/AppIcon.icns"
    "$PROJECT_DIR/Assets/AppIcon.icns"
    "$PROJECT_DIR/Resources/AppIcon.icns"
    "$PROJECT_DIR/dist/AppIcon.icns"
    "/Applications/${APP_DISPLAY_NAME}.app/Contents/Resources/AppIcon.icns"
    "$LEGACY_INSTALL_DIR/Contents/Resources/AppIcon.icns"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done

  return 1
}

sign_bundle_if_needed() {
  local bundle="$1"

  if [[ "$SKIP_SIGN" == "1" ]]; then
    log "Skipping codesign (SKIP_SIGN=1)"
    return 0
  fi

  if [[ -n "$RESOLVED_SIGN_IDENTITY" ]]; then
    log "Signing with identity: $RESOLVED_SIGN_IDENTITY"
    codesign --force --deep --options runtime --sign "$RESOLVED_SIGN_IDENTITY" "$bundle"
  else
    log "No Apple Development identity found; using ad-hoc signature"
    codesign --force --deep --sign - "$bundle"
  fi

  codesign --verify --deep --strict "$bundle"
}

resolve_sign_identity() {
  if [[ "$SKIP_SIGN" == "1" ]]; then
    return 0
  fi

  if [[ -n "$SIGN_IDENTITY" ]]; then
    RESOLVED_SIGN_IDENTITY="$SIGN_IDENTITY"
    return 0
  fi

  if [[ -d "$INSTALL_DIR" ]]; then
    local existing existing_info
    existing_info="$(codesign -dv --verbose=4 "$INSTALL_DIR" 2>&1 || true)"
    existing="$(printf '%s\n' "$existing_info" | awk -F= '/^Authority=Apple Development: /{print $2}' | sed -n '1p')"
    if [[ -n "$existing" ]]; then
      RESOLVED_SIGN_IDENTITY="$existing"
      return 0
    fi
  fi

  local identities_output first_available
  identities_output="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  first_available="$(printf '%s\n' "$identities_output" | awk -F '"' '/Apple Development: /{print $2; exit}')"
  if [[ -n "$first_available" ]]; then
    RESOLVED_SIGN_IDENTITY="$first_available"
  fi
}

resolve_sign_identity
if [[ -n "$RESOLVED_SIGN_IDENTITY" ]]; then
  log "Resolved signing identity: $RESOLVED_SIGN_IDENTITY"
fi

STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/transon-build.XXXXXX")"
APP_STAGE="$STAGING_ROOT/${APP_DISPLAY_NAME}.app"
cleanup() {
  if [[ -n "$STAGING_ROOT" && -d "$STAGING_ROOT" ]]; then
    rm -rf "$STAGING_ROOT"
  fi
}
trap cleanup EXIT

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
BIN_PATH="$BIN_DIR/$EXECUTABLE_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
  echo "Release binary not found: $BIN_PATH" >&2
  exit 1
fi

ICON_PATH=""
if ICON_PATH="$(pick_icon_source)"; then
  log "Using icon: $ICON_PATH"
else
  log "Icon not found; app will be built without custom icon"
fi

rm -rf "$APP_STAGE"
mkdir -p "$APP_STAGE/Contents/MacOS" "$APP_STAGE/Contents/Resources"
cp "$BIN_PATH" "$APP_STAGE/Contents/MacOS/${EXECUTABLE_NAME}"
chmod +x "$APP_STAGE/Contents/MacOS/${EXECUTABLE_NAME}"

if [[ -n "$ICON_PATH" ]]; then
  /usr/bin/ditto --norsrc "$ICON_PATH" "$APP_STAGE/Contents/Resources/AppIcon.icns"
  xattr -c "$APP_STAGE/Contents/Resources/AppIcon.icns" 2>/dev/null || true
  ICON_PLIST_BLOCK=$'  <key>CFBundleIconFile</key>\n  <string>AppIcon</string>'
else
  ICON_PLIST_BLOCK=""
fi

cat > "$APP_STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_DISPLAY_NAME}</string>
  <key>CFBundleExecutable</key>
  <string>${EXECUTABLE_NAME}</string>
${ICON_PLIST_BLOCK}
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${APP_DISPLAY_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${APP_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD_VERSION}</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

xattr -c "$APP_STAGE" 2>/dev/null || true
xattr -cr "$APP_STAGE" 2>/dev/null || true
sign_bundle_if_needed "$APP_STAGE"

mkdir -p "$(dirname "$APP_DIR")"
rm -rf "$APP_DIR"
/usr/bin/ditto --norsrc "$APP_STAGE" "$APP_DIR"

rm -rf "$INSTALL_DIR"
/usr/bin/ditto --norsrc "$APP_STAGE" "$INSTALL_DIR"
if [[ "$LEGACY_INSTALL_DIR" != "$INSTALL_DIR" ]]; then
  rm -rf "$LEGACY_INSTALL_DIR"
fi

xattr -cr "$INSTALL_DIR" || true
sign_bundle_if_needed "$INSTALL_DIR"

log "Built: $APP_DIR"
log "Installed: $INSTALL_DIR"
