#!/usr/bin/env bash
# Fetches the pinned Chromium Embedded Framework (CEF) binary distribution that
# Wink is built on and verifies its checksum. Idempotent: re-running is a no-op
# when the pinned version is already in place. On Apple silicon that is the
# build with proprietary codecs, from a release of ENGINE_REPO; on Intel, the
# official build from the CDN.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../engine.lock
source "$ROOT/engine.lock"

THIRD_PARTY="$ROOT/third_party"
DOWNLOADS="$THIRD_PARTY/downloads"
DEST="$THIRD_PARTY/cef"
STAMP="$DEST/.wink-engine-version"

# --- Sparkle (updates) ---------------------------------------------------------
SPARKLE_DEST="$THIRD_PARTY/sparkle"
if [[ "$(cat "$SPARKLE_DEST/.wink-sparkle-version" 2>/dev/null)" != "$SPARKLE_VERSION" ]]; then
  SPARKLE_ARCHIVE="$DOWNLOADS/Sparkle-$SPARKLE_VERSION.tar.xz"
  mkdir -p "$DOWNLOADS"
  if [[ ! -f "$SPARKLE_ARCHIVE" ]]; then
    echo "↓ Downloading Sparkle $SPARKLE_VERSION"
    curl --fail --location --silent --show-error -o "$SPARKLE_ARCHIVE.partial" \
      "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
    mv "$SPARKLE_ARCHIVE.partial" "$SPARKLE_ARCHIVE"
  fi
  if [[ "$(shasum -a 256 "$SPARKLE_ARCHIVE" | awk '{print $1}')" != "$SPARKLE_SHA256" ]]; then
    echo "error: sha256 mismatch for Sparkle-$SPARKLE_VERSION.tar.xz" >&2
    rm -f "$SPARKLE_ARCHIVE"
    exit 1
  fi
  rm -rf "$SPARKLE_DEST"
  mkdir -p "$SPARKLE_DEST"
  tar -xJf "$SPARKLE_ARCHIVE" -C "$SPARKLE_DEST" Sparkle.framework bin LICENSE
  echo "$SPARKLE_VERSION" > "$SPARKLE_DEST/.wink-sparkle-version"
  echo "✓ Sparkle $SPARKLE_VERSION ready at third_party/sparkle"
fi

# --- Chromium engine -----------------------------------------------------------
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
    ENCODED="$(python3 -I -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$ARCHIVE")"
    if ! curl --fail --location --progress-bar -o "$DOWNLOADS/$ARCHIVE.partial" \
        "https://github.com/$ENGINE_REPO/releases/download/$ENGINE_RELEASE/$ENCODED"; then
      # Not public (forks, CI before a release): fall back to an authenticated download.
      command -v gh > /dev/null || { echo "error: couldn't download the engine from $ENGINE_REPO" >&2; exit 1; }
      gh release download "$ENGINE_RELEASE" --repo "$ENGINE_REPO" --pattern "$ARCHIVE" \
        --output "$DOWNLOADS/$ARCHIVE.partial" --clobber
    fi
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
