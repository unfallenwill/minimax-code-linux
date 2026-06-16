#!/usr/bin/env bash
# DMG handling: locate/download, extract, and metadata detection.
# Technique learned from codex-desktop-linux (7z reads UDIF; detect Electron from
# the framework plist; fingerprint upstream via etag/last-modified/content-length),
# written from scratch for MiniMax Code.
# shellcheck shell=bash

# Resolve the DMG to use. If $1 is an existing path, use it; otherwise download
# from $MMX_UPSTREAM_DMG_URL. Echoes the local DMG path.
dmg_resolve() {
  local dmg="${1:-}"
  if [ -n "$dmg" ] && [ -f "$dmg" ]; then echo "$dmg"; return 0; fi
  [ -n "$MMX_UPSTREAM_DMG_URL" ] || die "No DMG provided. Pass --dmg <path> or set MMX_UPSTREAM_DMG_URL."
  mkdir -p "$MMX_CACHE_DIR"
  local dest="$MMX_CACHE_DIR/minimax-code.dmg"
  info "Downloading DMG from $MMX_UPSTREAM_DMG_URL ..."
  curl -fL --retry 3 --connect-timeout 30 -o "$dest" "$MMX_UPSTREAM_DMG_URL" \
    || die "DMG download failed"
  echo "$dest"
}

# Extract a DMG into $2 and echo the path to the *.app bundle inside it.
dmg_extract() {
  local dmg="$1" dest="$2"
  mkdir -p "$dest"
  info "Extracting DMG with 7z ..."
  local log="$dest/7z-extract.log"
  # 7z reads UDIF/HFS+ directly. It often exits non-zero on these images even
  # when extraction succeeds, so we check for the app bundle rather than the rc.
  7z x -y -bd -o"$dest" "$dmg" >"$log" 2>&1 || warn "7z reported errors (often benign for UDIF); see $log"
  local app
  app="$(find "$dest" -mindepth 1 -maxdepth 5 -name "*.app" -type d 2>/dev/null | head -1 || true)"
  [ -n "$app" ] || die "No .app bundle found inside DMG extraction"
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
