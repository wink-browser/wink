#!/usr/bin/env bash
# Fetches the pinned Chromium Embedded Framework (CEF) binary distribution that
# Wink is built on and verifies its checksum. Idempotent: re-running is a no-op
# when the pinned version is already in place. On Apple silicon that is the
# build with proprietary codecs, from a release of ENGINE_REPO (needs `gh`
# signed in with access to it); on Intel, the official build from the CDN.
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
  arm64)  PLATFORM="macosarm64"; FLAVOR="codecs";   HASH="sha256:$CEF_SHA256_MACOSARM64" ;;
  x86_64) PLATFORM="macosx64";   FLAVOR="official"; HASH="sha1:$CEF_SHA1_MACOSX64" ;;
  *) echo "error: unsupported architecture $ARCH" >&2; exit 1 ;;
esac

NAME="cef_binary_${CEF_VERSION}_${PLATFORM}_minimal"
ARCHIVE="$NAME.tar.bz2"

# The flavor is part of the stamp: both builds share a version and a file name.
if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$CEF_VERSION/$PLATFORM/$FLAVOR" ]]; then
  echo "✓ Chromium engine $CEF_VERSION ($PLATFORM, $FLAVOR) already present"
  exit 0
fi

DOWNLOADS="$DOWNLOADS/$FLAVOR"
mkdir -p "$DOWNLOADS"
if [[ ! -f "$DOWNLOADS/$ARCHIVE" ]]; then
  echo "↓ Downloading $ARCHIVE ($FLAVOR)"
  if [[ "$FLAVOR" == codecs ]]; then
    command -v gh > /dev/null || { echo "error: the engine is a release of $ENGINE_REPO; install gh and sign in" >&2; exit 1; }
    gh release download "$ENGINE_RELEASE" --repo "$ENGINE_REPO" --pattern "$ARCHIVE" \
      --output "$DOWNLOADS/$ARCHIVE.partial" --clobber
  else
    ENCODED="$(python3 -I -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$ARCHIVE")"
    curl --fail --location --progress-bar -o "$DOWNLOADS/$ARCHIVE.partial" "$CEF_CDN/$ENCODED"
  fi
  mv "$DOWNLOADS/$ARCHIVE.partial" "$DOWNLOADS/$ARCHIVE"
fi

echo "• Verifying checksum"
ALGORITHM="${HASH%%:*}"
EXPECTED="${HASH#*:}"
ACTUAL="$(shasum -a "${ALGORITHM#sha}" "$DOWNLOADS/$ARCHIVE" | awk '{print $1}')"
if [[ "$ACTUAL" != "$EXPECTED" ]]; then
  echo "error: $ALGORITHM mismatch for $ARCHIVE" >&2
  echo "  expected $EXPECTED" >&2
  echo "  actual   $ACTUAL" >&2
  rm -f "$DOWNLOADS/$ARCHIVE"
  exit 1
fi

echo "• Extracting"
rm -rf "$DEST" "$THIRD_PARTY/$NAME"
tar -xjf "$DOWNLOADS/$ARCHIVE" -C "$THIRD_PARTY"
mv "$THIRD_PARTY/$NAME" "$DEST"
echo "$CEF_VERSION/$PLATFORM/$FLAVOR" > "$STAMP"
echo "✓ Chromium engine ($FLAVOR) ready at third_party/cef"
