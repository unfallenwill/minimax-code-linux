#!/usr/bin/env bash
# Shared constants, logging, and helpers for the MiniMax Code Linux build.
# Sourced by install.sh and the scripts/lib_*.sh files. Do not execute directly.
# shellcheck shell=bash

set -o pipefail

# ---- Identity (overridable via env) ----
: "${MMX_APP_ID:=com.minimax.agent.cn}"
: "${MMX_PKG_NAME:=minimax-code}"
: "${MMX_DISPLAY:=MiniMax Code}"
: "${MMX_WMCLASS:=MiniMax Code}"
: "${MMX_BIN:=minimax-code}"
: "${MMX_INSTALL_PREFIX:=/opt/minimax-code}"     # in-package path used by nfpm templates
: "${MMX_ELECTRON_FALLBACK:=38.3.0}"
: "${MMX_ELECTRON_REPO:=electron/electron}"       # GitHub owner/repo for Electron releases
: "${MMX_UPSTREAM_DMG_URL:=}"                     # set for CI auto-download; empty => require --dmg
: "${MMX_CACHE_DIR:=$HOME/.cache/minimax-code-linux}"

# ---- Logging ----
_log() { printf '%s\n' "$*" >&2; }
info() { _log "[info] $*"; }
warn() { _log "[warn] $*"; }
die()  { _log "[error] $*"; exit 1; }

# ---- Helpers ----
# Fail if any of the listed commands is missing.
require_cmd() {
  local missing=() c
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  [ "${#missing[@]}" -eq 0 ] || die "Missing required commands: ${missing[*]}"
}

# Map a friendly arch token to npm/electron/deb/rpm arch strings.
# $1 = x64 | arm ; exports MMX_ELECTRON_ARCH MMX_NPM_ARCH MMX_DEB_ARCH MMX_RPM_ARCH
resolve_arch() {
  case "$1" in
    x64|amd64)
      MMX_ELECTRON_ARCH=x64 MMX_NPM_ARCH=x64 MMX_DEB_ARCH=amd64 MMX_RPM_ARCH=x86_64 ;;
    arm|arm64|aarch64)
      MMX_ELECTRON_ARCH=arm64 MMX_NPM_ARCH=arm64 MMX_DEB_ARCH=arm64 MMX_RPM_ARCH=aarch64 ;;
    *)
      die "Unknown arch '$1' (expected x64 or arm)" ;;
  esac
  export MMX_ELECTRON_ARCH MMX_NPM_ARCH MMX_DEB_ARCH MMX_RPM_ARCH
}
