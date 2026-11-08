#!/usr/bin/env bash
# Fetches the pinned Chromium Embedded Framework (CEF) binary distribution that
# Wink is built on and verifies its checksum. Idempotent: re-running is a no-op
# when the pinned version is already in place.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../engine.lock
source "$ROOT/engine.lock"

THIRD_PARTY="$ROOT/third_party"
DOWNLOADS="$THIRD_PARTY/downloads"
DEST="$THIRD_PARTY/cef"
STAMP="$DEST/.wink-engine-version"

ARCH="$(uname -m)"
case "$ARCH" in
  arm64)  PLATFORM="macosarm64"; SHA1="$CEF_SHA1_MACOSARM64" ;;
  x86_64) PLATFORM="macosx64";   SHA1="$CEF_SHA1_MACOSX64" ;;
  *) echo "error: unsupported architecture $ARCH" >&2; exit 1 ;;
esac

NAME="cef_binary_${CEF_VERSION}_${PLATFORM}_minimal"
ARCHIVE="$NAME.tar.bz2"

if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$CEF_VERSION/$PLATFORM" ]]; then
  echo "✓ Chromium engine $CEF_VERSION ($PLATFORM) already present"
  exit 0
fi

mkdir -p "$DOWNLOADS"
if [[ ! -f "$DOWNLOADS/$ARCHIVE" ]]; then
  ENCODED="$(python3 -I -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$ARCHIVE")"
  echo "↓ Downloading $ARCHIVE"
  curl --fail --location --progress-bar -o "$DOWNLOADS/$ARCHIVE.partial" "$CEF_CDN/$ENCODED"
  mv "$DOWNLOADS/$ARCHIVE.partial" "$DOWNLOADS/$ARCHIVE"
fi

echo "• Verifying checksum"
ACTUAL="$(shasum -a 1 "$DOWNLOADS/$ARCHIVE" | awk '{print $1}')"
if [[ "$ACTUAL" != "$SHA1" ]]; then
  echo "error: checksum mismatch for $ARCHIVE" >&2
  echo "  expected $SHA1" >&2
  echo "  actual   $ACTUAL" >&2
  rm -f "$DOWNLOADS/$ARCHIVE"
  exit 1
fi

echo "• Extracting"
rm -rf "$DEST" "$THIRD_PARTY/$NAME"
tar -xjf "$DOWNLOADS/$ARCHIVE" -C "$THIRD_PARTY"
mv "$THIRD_PARTY/$NAME" "$DEST"
echo "$CEF_VERSION/$PLATFORM" > "$STAMP"
echo "✓ Chromium engine ready at third_party/cef"
