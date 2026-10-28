#!/usr/bin/env bash
# Downloads the CEF (Chromium Embedded Framework) minimal binary distribution
# used by Arrow as its Chromium rendering engine.
set -euo pipefail

CEF_VERSION="${CEF_VERSION:-156.0.14+g4fa4ab5+chromium-156.0.8078.48}"
CEF_PLATFORM="${CEF_PLATFORM:-macosarm64}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Vendor/cef"
NAME="cef_binary_${CEF_VERSION}_${CEF_PLATFORM}_minimal"
URL="https://cef-builds.spotifycdn.com/$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$NAME.tar.bz2")"

if [[ -f "$DEST/.version" && "$(cat "$DEST/.version")" == "$NAME" ]]; then
  echo "CEF $CEF_VERSION already present in $DEST"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "Downloading $URL"
curl -fL --retry 3 -o "$TMP/cef.tar.bz2" "$URL"
curl -fsL -o "$TMP/cef.tar.bz2.sha1" "$URL.sha1"
echo "$(cat "$TMP/cef.tar.bz2.sha1")  $TMP/cef.tar.bz2" | shasum -a 1 -c -
tar -xjf "$TMP/cef.tar.bz2" -C "$TMP"
rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
mv "$TMP/$NAME" "$DEST"
echo "$NAME" > "$DEST/.version"
echo "CEF installed in $DEST"
