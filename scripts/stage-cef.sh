#!/usr/bin/env bash
# Installs the CEF runtime (libcef, its resources and locales) next to an
# executable built on Windows or Linux, where Chromium looks for it.
# Usage: scripts/stage-cef.sh <directory of the executable>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CEF="${CEF_ROOT:-$ROOT/Vendor/cef}"
DEST="${1:?usage: $0 <directory of the executable>}"

if [[ ! -d "$CEF/Release" || ! -d "$CEF/Resources" ]]; then
  echo "error: no CEF distribution in $CEF. Run ./scripts/fetch-cef.sh" >&2
  exit 1
fi

mkdir -p "$DEST"
for dir in "$CEF/Release" "$CEF/Resources"; do
  for item in "$dir"/*; do
    name="$(basename "$item")"
    case "$name" in
      # Import library and CEF's own bootstrap executables: not needed to run.
      *.lib | bootstrap*.exe) continue ;;
      # The setuid sandbox helper must be a real file (owned by root).
      chrome-sandbox) cp -f "$item" "$DEST/$name" ;;
      *)
        if [[ "$OSTYPE" == linux* ]]; then
          ln -sfn "$item" "$DEST/$name"
        else
          cp -rf "$item" "$DEST/"
        fi
        ;;
    esac
  done
done
echo "CEF runtime installed in $DEST"
