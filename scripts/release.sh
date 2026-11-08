#!/usr/bin/env bash
# Builds a distributable Wink: Developer ID signed, notarized and stapled,
# packed as a disk image ready to download.
#
#   WINK_SIGN_IDENTITY="Developer ID Application: … (TEAMID)" scripts/release.sh [output-dir]
#
# WINK_NOTARY_PROFILE names credentials saved once with
#   xcrun notarytool store-credentials wink-notary --apple-id … --team-id TEAMID
# (default: wink-notary), so no password is ever on a command line.
# WINK_SKIP_NOTARIZE=1 builds and signs only, for local checks.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${WINK_SIGN_IDENTITY:?set WINK_SIGN_IDENTITY to your \"Developer ID Application: … (TEAMID)\" identity}"
PROFILE="${WINK_NOTARY_PROFILE:-wink-notary}"
BUILD="${WINK_RELEASE_BUILD_DIR:-build-release}"
OUT_DIR="${1:-$BUILD/dist}"
VERSION="$(sed -nE 's/^project\(Wink VERSION ([0-9.]+).*/\1/p' CMakeLists.txt)"
APP="$BUILD/Wink.app"
DMG="$OUT_DIR/Wink-$VERSION.dmg"

step() { printf '\n▸ %s\n' "$*"; }

# Submits a file and waits; fails with Apple's log unless it is Accepted.
notarize() {
  local result id status
  result="$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --output-format json)"
  id="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("id",""))' "$result")"
  status="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("status",""))' "$result")"
  echo "  submission $id: $status"
  if [[ "$status" != "Accepted" ]]; then
    xcrun notarytool log "$id" --keychain-profile "$PROFILE" || true
    echo "✗ notarization of $1 was not accepted" >&2
    exit 1
  fi
}

step "Building Wink $VERSION for release"
./scripts/bootstrap.sh
# Release builds use the real Keychain for cookie encryption ("Wink Safe Storage").
cmake -S . -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release -DWINK_DEV_MOCK_KEYCHAIN=OFF \
      -DWINK_BUNDLE_ID=app.wink.browser >/dev/null
WINK_SIGN_IDENTITY="$IDENTITY" cmake --build "$BUILD"

step "Verifying signatures"
codesign --verify --deep --strict --verbose=1 "$APP"
# Every Mach-O must carry our Developer ID, the hardened runtime (executables)
# and a secure timestamp, or notarization will reject the whole app.
count=0
while IFS= read -r -d '' file; do
  file -b "$file" | grep -q '^Mach-O' || continue
  info="$(codesign -dvv "$file" 2>&1)"
  grep -qF "Authority=$IDENTITY" <<<"$info" || { echo "✗ not signed with $IDENTITY: $file" >&2; exit 1; }
  grep -q '^Timestamp=' <<<"$info" || { echo "✗ no secure timestamp: $file" >&2; exit 1; }
  if file -b "$file" | grep -q 'executable'; then
    grep -q 'flags=.*runtime' <<<"$info" || { echo "✗ no hardened runtime: $file" >&2; exit 1; }
  fi
  count=$((count + 1))
done < <(find "$APP" -type f -print0)
echo "  $count binaries signed, timestamped, hardened"

if [[ "${WINK_SKIP_NOTARIZE:-0}" != 1 ]]; then
  step "Notarizing the app"
  zip="$BUILD/Wink-$VERSION-notarize.zip"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$zip"
  notarize "$zip"
  rm -f "$zip"
  xcrun stapler staple "$APP"
fi

step "Making the disk image"
mkdir -p "$OUT_DIR"
stage="$(mktemp -d)"
ditto "$APP" "$stage/Wink.app"
ln -s /Applications "$stage/Applications"
rm -f "$DMG"
hdiutil create -volname "Wink" -srcfolder "$stage" -format ULMO -ov "$DMG" >/dev/null
rm -rf "$stage"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

if [[ "${WINK_SKIP_NOTARIZE:-0}" != 1 ]]; then
  step "Notarizing the disk image"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  step "Gatekeeper"
  spctl --assess --type execute --verbose=2 "$APP"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

(cd "$OUT_DIR" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
step "Done"
echo "✓ $DMG ($(du -h "$DMG" | cut -f1)), sha256 in $(basename "$DMG").sha256"
