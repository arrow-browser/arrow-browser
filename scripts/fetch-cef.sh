#!/usr/bin/env bash
# Downloads the CEF (Chromium Embedded Framework) minimal binary distribution
# used by Arrow as its Chromium rendering engine.
set -euo pipefail

CEF_VERSION="${CEF_VERSION:-156.0.14+g4fa4ab5+chromium-156.0.8078.48}"

# The distribution of this machine unless CEF_PLATFORM is set: macosarm64,
# macosx64, windows64, windowsarm64, linux64 or linuxarm64.
if [[ -z "${CEF_PLATFORM:-}" ]]; then
  case "$(uname -s)" in
    Darwin) os=macos ;;
    Linux) os=linux ;;
    MINGW* | MSYS* | CYGWIN*) os=windows ;;
    *) echo "error: unsupported system $(uname -s)" >&2; exit 1 ;;
  esac
  case "$(uname -m)" in
    arm64 | aarch64) arch=arm64 ;;
    x86_64 | amd64) arch=$([[ $os == macos ]] && echo x64 || echo 64) ;;
    *) echo "error: unsupported architecture $(uname -m)" >&2; exit 1 ;;
  esac
  CEF_PLATFORM="$os$arch"
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Vendor/cef"
NAME="cef_binary_${CEF_VERSION}_${CEF_PLATFORM}_minimal"
PYTHON="$(command -v python3 || command -v python)"
URL="https://cef-builds.spotifycdn.com/$("$PYTHON" -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$NAME.tar.bz2")"

if [[ -f "$DEST/.version" && "$(cat "$DEST/.version")" == "$NAME" ]]; then
  echo "CEF $CEF_VERSION already present in $DEST"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "Downloading $URL"
curl -fL --retry 3 -o "$TMP/cef.tar.bz2" "$URL"
curl -fsL -o "$TMP/cef.tar.bz2.sha1" "$URL.sha1"
SHA1="$(command -v sha1sum || echo "shasum -a 1")"
echo "$(cat "$TMP/cef.tar.bz2.sha1")  $TMP/cef.tar.bz2" | $SHA1 -c -
tar -xjf "$TMP/cef.tar.bz2" -C "$TMP"
rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
mv "$TMP/$NAME" "$DEST"
echo "$NAME" > "$DEST/.version"
echo "CEF installed in $DEST"
