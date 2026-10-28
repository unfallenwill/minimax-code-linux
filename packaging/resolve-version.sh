#!/usr/bin/env bash
# Resolve the newest published MiniMax Code version + a fetchable macOS DMG URL.
# Prints two lines:
#   <version>      e.g. 3.1.7
#   <dmg-url>      fetchable DMG URL
#
# Usage: resolve-version.sh [version]
#   With an explicit version the URL is resolved for THAT version (still
#   HEAD-checked), so a workflow_dispatch can never pair an older version
#   request with a newer DMG or vice versa.
#
# Independent sources are queried and the HIGHEST version that passes a HEAD
# check wins. Order matters less than validation because they lag differently:
#   1. electron-updater latest-mac.yml at the -prod release dir. Published at
#      release time and carries the exact asset name, so it is authoritative.
#   2. web common_config. This lags: it kept advertising 3.1.6 after 3.1.7 had
#      shipped. It cannot win if a newer manifest version validates, and a
#      stale/404 entry never wins because every URL is HEAD-checked.
#
# The extracted app.asar payload is architecture-independent, so the x64 DMG is
# used for the x64 Linux build (only the Linux Electron runtime differs per
# target arch).
#
# Env:
#   MMX_REGION        cn (default) | overseas — selects the edition/CDN.
#   MMX_MANIFEST_URL  override the latest-mac.yml URL.
#   MMX_MANIFEST_BASE override the release directory used to synthesize URLs.
#   MMX_CONFIG_URL    override the common_config URL (empty string disables it).
set -euo pipefail

REGION="${MMX_REGION:-cn}"
if [ "$REGION" = "overseas" ]; then
  MANIFEST_BASE="${MMX_MANIFEST_BASE:-https://file.cdn.minimax.io/public/minimax-agent-prod/release}"
else
  MANIFEST_BASE="${MMX_MANIFEST_BASE:-https://filecdn.minimax.chat/public/minimax-agent-prod/release}"
fi
MANIFEST_URL="${MMX_MANIFEST_URL:-$MANIFEST_BASE/latest-mac.yml}"
CONFIG_URL="${MMX_CONFIG_URL:-https://agent.minimaxi.com/v1/api/config/web/common_config}"
WANTED="${1:-${MMX_VERSION:-}}"

log() { printf 'resolve-version: %s\n' "$*" >&2; }

if [ -n "$WANTED" ] && ! printf '%s' "$WANTED" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  log "invalid version '$WANTED' (expected X.Y.Z)"
  exit 2
fi

_curl_get() {
  curl -fsSL --retry 2 --retry-delay 1 --connect-timeout 10 --max-time 30 \
    -A "Mozilla/5.0" "$1"
}

# A candidate is only usable if the asset itself is fetchable. This is what
# keeps a stale common_config entry (or a half-published release) from winning.
_url_ok() {
  curl -fsSIL --retry 2 --retry-delay 1 --connect-timeout 10 --max-time 30 \
    -A "Mozilla/5.0" -o /dev/null "$1" && return 0
  # Some CDNs answer HEAD with 405; a one-byte ranged GET is the fallback.
  curl -fsSL -r 0-0 --retry 2 --retry-delay 1 --connect-timeout 10 --max-time 30 \
    -A "Mozilla/5.0" -o /dev/null "$1"
}

_newer() { # _newer <a> <b> -> true if a > b
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | tail -1)" = "$1" ]
}

urlencode_spaces() { printf '%s' "$1" | sed 's/ /%20/g'; }

# ---- Source 1: electron-updater manifest ------------------------------------
MANIFEST_CAND=""
if yml="$(_curl_get "$MANIFEST_URL" 2>/dev/null)" && [ -n "$yml" ]; then
  mver="$(printf '%s\n' "$yml" | sed -n 's/^version:[[:space:]]*//p' | head -1 | tr -d "'\"\r")"
  mrel="$(printf '%s\n' "$yml" | sed -n 's/^[[:space:]]*-[[:space:]]*url:[[:space:]]*//p' \
          | grep -E '\.dmg$' | grep -v 'arm64' | head -1 || true)"
  if [ -n "$mver" ] && [ -n "$mrel" ]; then
    case "$mrel" in
      *"$mver"*) MANIFEST_CAND="$mver|$MANIFEST_BASE/$(urlencode_spaces "$mrel")" ;;
      *) log "ignoring manifest: version $mver does not match asset '$mrel'" ;;
    esac
  else
    log "manifest has no version/x64 DMG entry: $MANIFEST_URL"
  fi
else
  log "manifest unavailable: $MANIFEST_URL"
fi

# ---- Source 2: web common_config --------------------------------------------
CONFIG_CAND=""
if [ -n "$CONFIG_URL" ]; then
  json="$(_curl_get "$CONFIG_URL" 2>/dev/null || true)"
  if [ -n "$json" ]; then
    url="$(printf '%s\n' "$json" | MMX_REGION="$REGION" python3 -c '
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
' 2>/dev/null || true)"
    if [ -n "$url" ]; then
      ver="$(printf '%s' "$url" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
      if [ -n "$ver" ]; then CONFIG_CAND="$ver|$url"; fi
    fi
  else
    log "common_config unavailable: $CONFIG_URL"
  fi
fi

# ---- Pick the newest candidate that is actually fetchable -------------------
BEST=""
for cand in "$MANIFEST_CAND" "$CONFIG_CAND"; do
  [ -n "$cand" ] || continue
  v="${cand%%|*}"
  u="${cand#*|}"
  if [ -n "$WANTED" ] && [ "$v" != "$WANTED" ]; then
    continue
  fi
  if _url_ok "$u"; then
    if [ -z "$BEST" ] || _newer "$v" "${BEST%%|*}"; then
      BEST="$cand"
    fi
  else
    log "skipping $v: DMG not fetchable: $u"
  fi
done

# Explicit version not offered by either source (e.g. config rolled back but
# the asset is still on the CDN): synthesize the canonical asset name.
if [ -z "$BEST" ] && [ -n "$WANTED" ]; then
  u="$MANIFEST_BASE/MiniMax%20Code-$(urlencode_spaces "$WANTED").dmg"
  if _url_ok "$u"; then
    BEST="$WANTED|$u"
  else
    log "requested version $WANTED has no fetchable DMG: $u"
  fi
fi

[ -n "$BEST" ] || { log "could not resolve a fetchable MiniMax Code version/URL"; exit 1; }

printf '%s\n%s\n' "${BEST%%|*}" "${BEST#*|}"
