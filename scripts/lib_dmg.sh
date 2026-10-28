#!/usr/bin/env bash
# DMG handling: locate/download, extract, and metadata detection.
# Technique learned from codex-desktop-linux (7z reads UDIF; detect Electron from
# the framework plist; fingerprint upstream via etag/last-modified/content-length),
# written from scratch for MiniMax Code.
# shellcheck shell=bash

# Resolve the DMG to use. If $1 is a non-empty path it must be an existing file
# (a typo'd path is an error, never a silent fallback to the URL); otherwise
# download from $MMX_UPSTREAM_DMG_URL into the cache. Echoes the local DMG path.
# The download goes through fetch_to_cache: the cache file is replaced atomically
# only after a complete download, so a failed download never corrupts a cached
# DMG.
dmg_resolve() {
  local dmg="${1:-}"
  if [ -n "$dmg" ]; then
    [ -f "$dmg" ] || die "DMG not found: $dmg"
    echo "$dmg"; return 0
  fi
  [ -n "$MMX_UPSTREAM_DMG_URL" ] || die "No DMG provided. Pass --dmg <path> or set MMX_UPSTREAM_DMG_URL."
  local dest="$MMX_CACHE_DIR/minimax-code.dmg"
  fetch_to_cache "$MMX_UPSTREAM_DMG_URL" "$dest" || die "DMG download failed"
  echo "$dest"
}

# Upstream switched the DMG to XZ-compressed HFS+ (UDIF "Zero2 XZ") in 3.1.6.
# 7-Zip gained that decoder in 24.01; older p7zip (16.02/17.05, still the
# default on many distros and CI images) fails with "Unsupported Method" and
# extracts no .app. Pick the newest binary available: `7zz` is the official
# console build, `7z` may be p7zip.
MMX_7Z_MIN_VERSION="24.01"
MMX_7Z_BIN=""
MMX_7Z_VERSION=""

_ver_ge() { # _ver_ge <have> <need>
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | tail -1)" = "$1" ]
}

seven_zip_pick() {
  if [ -n "$MMX_7Z_BIN" ]; then return 0; fi
  local c v best="" bestver=""
  for c in 7z 7zz; do   # later entries win ties, so official 7zz is preferred
    command -v "$c" >/dev/null 2>&1 || continue
    # Version banner is the first non-empty line, but 7zz prints a leading
    # blank line, so take the first version-like token anywhere in the output.
    v="$("$c" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)"
    [ -n "$v" ] || v="0.0"
    if [ -z "$best" ] || _ver_ge "$v" "$bestver"; then
      best="$c" bestver="$v"
    fi
  done
  [ -n "$best" ] || die "No 7-Zip binary found (need 7zz or 7z >= $MMX_7Z_MIN_VERSION for XZ-compressed DMGs)"
  MMX_7Z_BIN="$best" MMX_7Z_VERSION="$bestver"
  if ! _ver_ge "$bestver" "$MMX_7Z_MIN_VERSION"; then
    warn "7-Zip $bestver ($best) predates XZ-DMG support; upstream 3.1.6+ images need >= $MMX_7Z_MIN_VERSION"
  fi
}

require_7z() { seven_zip_pick; }

# Extract a DMG into $2 and echo the path to the *.app bundle inside it.
dmg_extract() {
  local dmg="$1" dest="$2"
  seven_zip_pick
  mkdir -p "$dest"
  info "Extracting DMG with $MMX_7Z_BIN $MMX_7Z_VERSION ..."
  local log="$dest/7z-extract.log"
  # 7z reads UDIF/HFS+ directly. It often exits non-zero on these images even
  # when extraction succeeds, so we check for the app bundle rather than the rc.
  "$MMX_7Z_BIN" x -y -bd -o"$dest" "$dmg" >"$log" 2>&1 \
    || warn "$MMX_7Z_BIN reported errors (often benign for UDIF); see $log"
  local app
  app="$(find "$dest" -mindepth 1 -maxdepth 5 -name "*.app" -type d 2>/dev/null | head -1 || true)"
  [ -n "$app" ] || die "No .app bundle found inside DMG extraction (7-Zip $MMX_7Z_VERSION via $MMX_7Z_BIN). Upstream DMGs need 7-Zip >= $MMX_7Z_MIN_VERSION for XZ compression; see $log"
  info "Found app bundle: $(basename "$app")"
  echo "$app"
}

# Read a value from a (binary or XML) Info.plist via python3 plistlib.
# $1 = plist path, $2 = key
_plist_get() {
  python3 - "$1" "$2" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    v = plistlib.load(f).get(sys.argv[2], "")
print("" if v is None else (v if isinstance(v, str) else str(v)))
PY
}

# Detect the Electron version the app was built with. Echoes e.g. 38.3.0.
dmg_detect_electron() {
  local app="$1"
  local plist="$app/Contents/Frameworks/Electron Framework.framework/Versions/A/Resources/Info.plist"
  local v=""
  [ -f "$plist" ] && v="$(_plist_get "$plist" CFBundleVersion)"
  if [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    info "Detected Electron: $v"; echo "$v"; return 0
  fi
  warn "Could not detect Electron from framework plist; using fallback $MMX_ELECTRON_FALLBACK"
  echo "$MMX_ELECTRON_FALLBACK"
}

# Read the app's marketing version, e.g. 3.0.43.
dmg_app_version() {
  local app="$1" v
  v="$(_plist_get "$app/Contents/Info.plist" CFBundleShortVersionString)"
  [ -n "$v" ] && echo "$v" || echo "0.0.0"
}

# Build an upstream freshness fingerprint for a URL (HEAD request).
# Echoes "etag=...|last_modified=...|content_length=...". Returns 1 if absent.
dmg_remote_fingerprint() {
  local url="$1"
  curl -fsSLI --max-time 15 --connect-timeout 5 "$url" 2>/dev/null | awk '
    BEGIN{IGNORECASE=1; e=m=c=""}
    /^etag:/{e=$0; sub(/^etag:[[:space:]]*/,"",e); gsub(/\r/,"",e)}
    /^last-modified:/{m=$0; sub(/^last-modified:[[:space:]]*/,"",m); gsub(/\r/,"",m)}
    /^content-length:/{c=$0; sub(/^content-length:[[:space:]]*/,"",c); gsub(/\r/,"",c)}
    END{ if(e==""&&m==""&&c=="") exit 1; printf "etag=%s|last_modified=%s|content_length=%s\n", e, m, c }
  '
}
