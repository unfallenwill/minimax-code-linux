#!/usr/bin/env bash
# Resolve the latest MiniMax Code version + the DMG download URL.
# Prints two lines:
#   <version>      e.g. 3.0.43
#   <dmg-url>      fetchable URL for CI to download the DMG bytes
#
# Strategies (first hit wins):
#   1. electron-updater manifest: <url>/latest-mac.yml  -> version + files[].url
#      (authoritative once MiniMax publishes it)
#   2. candidate stable DMG filenames at the manifest base, version parsed from
#      the name
#   3. (fallback) nothing resolvable -> exit 1; CI then uses a manual dmg_url.
set -euo pipefail
MANIFEST="${MMX_MANIFEST_URL:-https://filecdn.minimax.chat/public/minimax-agent/release}"

# --- Strategy 1: latest-mac.yml ---
if mac="$(curl -fsSL --max-time 20 "$MANIFEST/latest-mac.yml" 2>/dev/null)" && [ -n "$mac" ]; then
  ver="$(printf '%s\n' "$mac" | awk '/^version:/{print $2; exit}')"
  rel="$(printf '%s\n' "$mac" | awk '/^[[:space:]]+-[[:space:]]+url:/{print $3; exit}')"
  if [ -n "$ver" ] && [ -n "$rel" ]; then
    printf '%s\n%s\n' "$ver" "$MANIFEST/$rel"
    exit 0
  fi
fi

# --- Strategy 2: well-known DMG filenames ---
for f in "MiniMax Code.dmg" "minimax-code.dmg"; do
  url="$MANIFEST/$f"
  code="$(curl -sSL -o /dev/null -w '%{http_code}' --max-time 15 -I "$url" 2>/dev/null || true)"
  if [ "$code" = 200 ] || [ "$code" = 302 ]; then
    ver="$(curl -sIL --max-time 15 "$url" 2>/dev/null | awk -F'= ' 'tolower($1)~/content-disposition/{print $2}' \
           | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    [ -n "$ver" ] || ver="$(printf '%s' "$url" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    if [ -n "$ver" ]; then printf '%s\n%s\n' "$ver" "$url"; exit 0; fi
  fi
done

echo "resolve-version: could not resolve a MiniMax Code DMG URL from $MANIFEST" >&2
echo "Trigger build.yml manually with an explicit dmg_url input." >&2
exit 1
