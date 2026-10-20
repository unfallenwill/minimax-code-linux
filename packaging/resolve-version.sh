#!/usr/bin/env bash
# Resolve the latest MiniMax Code version + a fetchable macOS DMG URL.
# Prints two lines:
#   <version>      e.g. 3.0.43
#   <dmg-url>      fetchable DMG URL
#
# The extracted app.asar payload is architecture-independent, so the x64 DMG is
# used for the x64 Linux build (only the Linux Electron runtime and
# the opencode-linux-<arch> binary differ per target arch).
#
# Strategy 1 (primary): MiniMax's web common_config exposes per-platform download
# URLs with the version embedded in the filename. Anonymously fetchable, no login.
# Strategy 2 (fallback): electron-updater latest-mac.yml at their release URL.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib_common.sh
. "$ROOT/scripts/lib_common.sh"

CONFIG_URL="${MMX_CONFIG_URL:-https://agent.minimaxi.com/v1/api/config/web/common_config}"

json="$(curl -fsSL --max-time 20 -A "Mozilla/5.0" "$CONFIG_URL" 2>/dev/null || true)"
if [ -n "$json" ]; then
  # MMX_REGION selects which edition to package: "cn" (default, com.minimax.agent.cn,
  # filecdn.minimax.chat, minimax-cn scheme) or "overseas" (file.cdn.minimax.io).
  # The per-edition identity used by the rest of the build lives in
  # scripts/lib_common.sh; keep the two in sync.
  url="$(printf '%s\n' "$json" | MMX_REGION="${MMX_REGION:-cn}" python3 -c '
import os, sys, json
try:
    j = json.load(sys.stdin)
except Exception:
    sys.exit(0)
ac = (j.get("data") or {}).get("agent_config") or {}
keys = (("cnX64MacosDownloadUrl", "overseasX64MacosDownloadUrl")
        if os.environ.get("MMX_REGION", "cn") != "overseas"
        else ("overseasX64MacosDownloadUrl", "cnX64MacosDownloadUrl"))
for k in keys:
    v = ac.get(k)
    if v:
        print(v); break
' 2>/dev/null)"
  if [ -n "$url" ]; then
    ver="$(printf '%s' "$url" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    if [ -n "$ver" ]; then
      printf '%s\n%s\n' "$ver" "$url"
      exit 0
    fi
  fi
fi

MANIFEST="${MMX_MANIFEST_URL:-$MMX_REGION_MANIFEST}"
if mac="$(curl -fsSL --max-time 20 "$MANIFEST/latest-mac.yml" 2>/dev/null)" && [ -n "$mac" ]; then
  ver="$(printf '%s\n' "$mac" | awk '/^version:/{print $2; exit}')"
  rel="$(printf '%s\n' "$mac" | awk '/^[[:space:]]+-[[:space:]]+url:/{print $3; exit}')"
  if [ -n "$ver" ] && [ -n "$rel" ]; then
    printf '%s\n%s\n' "$ver" "$MANIFEST/$rel"
    exit 0
  fi
fi

echo "resolve-version: could not resolve MiniMax Code version/URL" >&2
exit 1
