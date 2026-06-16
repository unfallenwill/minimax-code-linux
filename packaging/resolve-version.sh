#!/usr/bin/env bash
# Resolve the latest MiniMax Code version + a fetchable macOS DMG URL.
# Prints two lines:
#   <version>      e.g. 3.0.43
#   <dmg-url>      fetchable DMG URL
#
# The extracted app.asar payload is architecture-independent, so the x64 DMG is
# used for both x64 and arm64 Linux builds (only the Linux Electron runtime and
# the opencode-linux-<arch> binary differ per target arch).
#
# Strategy 1 (primary): MiniMax's web common_config exposes per-platform download
# URLs with the version embedded in the filename. Anonymously fetchable, no login.
# Strategy 2 (fallback): electron-updater latest-mac.yml at their release URL.
set -euo pipefail
CONFIG_URL="${MMX_CONFIG_URL:-https://agent.minimaxi.com/v1/api/config/web/common_config}"

json="$(curl -fsSL --max-time 20 -A "Mozilla/5.0" "$CONFIG_URL" 2>/dev/null || true)"
if [ -n "$json" ]; then
  # MMX_REGION selects which edition to package: "cn" (default, com.minimax.agent.cn,
  # filecdn.minimax.chat, minimax-cn scheme) or "overseas" (file.cdn.minimax.io).
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

MANIFEST="${MMX_MANIFEST_URL:-https://filecdn.minimax.chat/public/minimax-agent/release}"
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
