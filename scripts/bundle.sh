#!/usr/bin/env bash
# Assembles Wink.app from the built binaries and the Chromium engine, then
# ad-hoc signs it (inside-out). Incremental: the 300+ MB framework is only
# re-copied when it changes.
set -euo pipefail

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --app) APP_BIN="$2"; shift 2 ;;
    --helper) HELPER_BIN="$2"; shift 2 ;;
    --bridge) BRIDGE_BIN="$2"; shift 2 ;;
    --cef) CEF_RELEASE="$2"; shift 2 ;;
    --sparkle) SPARKLE_FRAMEWORK="$2"; shift 2 ;;
    --resources) RES="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

APP_NAME="Wink"
BUNDLE_ID="${BUNDLE_ID:-app.wink.browser}"
CONTENTS="$OUT/Contents"
FRAMEWORKS="$CONTENTS/Frameworks"
CEF_FRAMEWORK_NAME="Chromium Embedded Framework.framework"
SIGN_IDENTITY="${WINK_SIGN_IDENTITY:--}"

mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$FRAMEWORKS"

render_plist() { # template output name identifier
  sed -e "s|\${EXECUTABLE_NAME}|$3|g" \
      -e "s|\${PRODUCT_NAME}|$3|g" \
      -e "s|\${BUNDLE_ID}|$4|g" \
      -e "s|\${VERSION}|$VERSION|g" \
      "$1" > "$2.tmp"
  if ! cmp -s "$2.tmp" "$2" 2>/dev/null; then mv "$2.tmp" "$2"; else rm "$2.tmp"; fi
}

copy_if_changed() { # src dst — returns 0 when it copied
  # Copy then rename: a running Wink keeps its old inode instead of having
  # its signed executable rewritten underneath it.
  if ! cmp -s "$1" "$2" 2>/dev/null; then cp -f "$1" "$2.tmp.$$" && mv -f "$2.tmp.$$" "$2"; return 0; fi
  return 1
}

# --- Main executable, MCP bridge, Info.plist ---------------------------------
copy_if_changed "$APP_BIN" "$CONTENTS/MacOS/$APP_NAME" || true
copy_if_changed "$BRIDGE_BIN" "$CONTENTS/MacOS/wink-mcp" || true
render_plist "$RES/Info.plist.in" "$CONTENTS/Info.plist" "$APP_NAME" "$BUNDLE_ID"
printf 'APPL????' > "$CONTENTS/PkgInfo"

# --- Resources ---------------------------------------------------------------
if [[ -f "$RES/AppIcon.icns" ]]; then copy_if_changed "$RES/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns" || true; fi
for asset in WinkEye.png Winky.jpg WinkyAvatar.jpg; do
  if [[ -f "$RES/$asset" ]]; then copy_if_changed "$RES/$asset" "$CONTENTS/Resources/$asset" || true; fi
done
if [[ -d "$RES/blocklist" ]]; then
  mkdir -p "$CONTENTS/Resources/blocklist"
  rsync -a --delete "$RES/blocklist/" "$CONTENTS/Resources/blocklist/"
fi
if [[ -d "$RES/agent" ]]; then
  mkdir -p "$CONTENTS/Resources/agent"
  rsync -a --delete "$RES/agent/" "$CONTENTS/Resources/agent/"
fi

# --- Chromium framework (versioned layout required by Xcode 26 codesign) -----
# Copied and signed only when the pinned engine version changes.
FW="$FRAMEWORKS/$CEF_FRAMEWORK_NAME"
ENGINE_STAMP="$(cat "$CEF_RELEASE/../.wink-engine-version" 2>/dev/null || echo unknown)/$SIGN_IDENTITY"
STAMP_FILE="$(dirname "$OUT")/.wink-framework-stamp"   # outside the sealed bundle
FRAMEWORK_CHANGED=0
if [[ ! -d "$FW/Versions/A" || "$(cat "$STAMP_FILE" 2>/dev/null)" != "$ENGINE_STAMP" ]]; then
  FRAMEWORK_CHANGED=1
  rm -rf "$FW"
  mkdir -p "$FW/Versions/A"
  # Ship English resources only for now (saves ~40 MB of locale packs).
  rsync -a --delete-excluded \
    --include "/Resources/en.lproj/" --exclude "/Resources/*.lproj/" \
    --exclude "_CodeSignature/" \
    "$CEF_RELEASE/$CEF_FRAMEWORK_NAME/" "$FW/Versions/A/"
  ln -sfn "A" "$FW/Versions/Current"
  ln -sfn "Versions/A/Chromium Embedded Framework" "$FW/Chromium Embedded Framework"
  ln -sfn "Versions/A/Libraries" "$FW/Libraries"
  ln -sfn "Versions/A/Resources" "$FW/Resources"
fi

# --- Sparkle (updates) ----------------------------------------------------------
# Copied with its symlinks, without the XPC services (only sandboxed apps
# need them), and re-signed below when its version or the identity changes.
SPK="$FRAMEWORKS/Sparkle.framework"
SPARKLE_STAMP="$(cat "$SPARKLE_FRAMEWORK/../.wink-sparkle-version" 2>/dev/null || echo unknown)/$SIGN_IDENTITY"
SPARKLE_STAMP_FILE="$(dirname "$OUT")/.wink-sparkle-stamp"
SPARKLE_CHANGED=0
if [[ ! -d "$SPK/Versions/B" || "$(cat "$SPARKLE_STAMP_FILE" 2>/dev/null)" != "$SPARKLE_STAMP" ]]; then
  SPARKLE_CHANGED=1
  rm -rf "$SPK"
  rsync -a --exclude "XPCServices" --exclude "_CodeSignature/" "$SPARKLE_FRAMEWORK/" "$SPK/"
fi

# --- Helper apps (one per Chromium process type) -----------------------------
HELPERS_CHANGED=0
for spec in ":" " (Alerts):.alerts" " (GPU):.gpu" " (Plugin):.plugin" " (Renderer):.renderer"; do
  SUFFIX="${spec%%:*}"
  ID_SUFFIX="${spec#*:}"
  NAME="$APP_NAME Helper$SUFFIX"
  HAPP="$FRAMEWORKS/$NAME.app/Contents"
  mkdir -p "$HAPP/MacOS"
  if copy_if_changed "$HELPER_BIN" "$HAPP/MacOS/$NAME"; then HELPERS_CHANGED=1; fi
  if [[ ! -d "$HAPP/_CodeSignature" ]]; then HELPERS_CHANGED=1; fi
  BEFORE="$(cat "$HAPP/Info.plist" 2>/dev/null || true)"
  render_plist "$RES/helper-Info.plist.in" "$HAPP/Info.plist" "$NAME" "$BUNDLE_ID.helper$ID_SUFFIX"
  if [[ "$BEFORE" != "$(cat "$HAPP/Info.plist")" ]]; then HELPERS_CHANGED=1; fi
  printf 'APPL????' > "$HAPP/PkgInfo"
done

# --- Code signing (inside-out) -----------------------------------------------
# Dev builds are ad-hoc signed. With WINK_SIGN_IDENTITY set to a Developer ID,
# everything is signed for distribution: hardened runtime, secure timestamp,
# and per-process entitlements (Chromium's helpers JIT-compile JavaScript).
DEVELOPER_ID=0
[[ "$SIGN_IDENTITY" != "-" ]] && DEVELOPER_ID=1
ENTITLEMENTS="$RES/Entitlements"

sign() { # [--entitlements file] path...
  local args=(--force --sign "$SIGN_IDENTITY")
  if [[ "$DEVELOPER_ID" == 1 ]]; then args+=(--options runtime --timestamp); else args+=(--timestamp=none); fi
  local output status=0
  output="$(codesign "${args[@]}" "$@" 2>&1)" || status=$?
  if [[ -n "$output" ]]; then grep -v "replacing existing signature" <<<"$output" >&2 || true; fi
  return $status
}

entitled() { # entitlements-name path — entitlements only for Developer ID builds
  if [[ "$DEVELOPER_ID" == 1 ]]; then sign --entitlements "$ENTITLEMENTS/$1.plist" "$2"; else sign "$2"; fi
}

if [[ "$FRAMEWORK_CHANGED" == 1 ]]; then
  sign "$FW/Versions/A/Libraries/"*.dylib
  sign "$FW"
  echo "$ENGINE_STAMP" > "$STAMP_FILE"
fi
if [[ "$SPARKLE_CHANGED" == 1 ]]; then
  sign "$SPK/Versions/B/Autoupdate"
  sign "$SPK/Versions/B/Updater.app"
  sign "$SPK"
  echo "$SPARKLE_STAMP" > "$SPARKLE_STAMP_FILE"
fi
# Helpers are re-signed only when they (or the identity) changed, so
# renderers of a running Wink never see their executables touched.
HELPER_STAMP="$(dirname "$OUT")/.wink-helpers-stamp"
if [[ "$(cat "$HELPER_STAMP" 2>/dev/null)" != "$SIGN_IDENTITY" ]]; then HELPERS_CHANGED=1; fi
if [[ "$HELPERS_CHANGED" == 1 || "$FRAMEWORK_CHANGED" == 1 ]]; then
  entitled helper "$FRAMEWORKS/$APP_NAME Helper.app"
  entitled helper-renderer "$FRAMEWORKS/$APP_NAME Helper (Renderer).app"
  entitled helper-gpu "$FRAMEWORKS/$APP_NAME Helper (GPU).app"
  entitled helper-plugin "$FRAMEWORKS/$APP_NAME Helper (Plugin).app"
  entitled helper-alerts "$FRAMEWORKS/$APP_NAME Helper (Alerts).app"
  echo "$SIGN_IDENTITY" > "$HELPER_STAMP"
fi
sign "$CONTENTS/MacOS/wink-mcp"
entitled app "$OUT"
touch "$OUT"
echo "✓ $OUT"
