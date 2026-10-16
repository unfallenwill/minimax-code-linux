#!/usr/bin/env bash
# Download and unpack the official Linux Electron runtime of a given version/arch
# directly into the (staged) install root, so its resources/ sits beside the
# MiniMax payload (resources/app, resources/resources/daemon).
# shellcheck shell=bash

# Validate a cached Electron archive: non-empty AND structurally intact
# (unzip -t checks every member's CRC). Guards against truncated downloads
# from older runs or a full disk silently breaking the unpack stage.
_electron_zip_ok() {
  [ -s "$1" ] || return 1
  unzip -tqq "$1" >/dev/null 2>&1
}

# $1 = electron version, $2 = electron arch (x64), $3 = install root dir
electron_install() {
  local ver="$1" arch="$2" dest="$3"
  local asset="electron-v${ver}-linux-${arch}.zip"
  local url="https://github.com/${MMX_ELECTRON_REPO}/releases/download/v${ver}/${asset}"
  local cache="$MMX_CACHE_DIR/electron"
  mkdir -p "$cache" "$dest"
  local zip="$cache/$asset"
  if [ -s "$zip" ] && ! _electron_zip_ok "$zip"; then
    warn "Cached Electron archive failed validation, re-downloading: $zip"
    rm -f "$zip"
  fi
  if [ ! -s "$zip" ]; then
    # fetch_to_cache validates the archive before publishing it (and a failed
    # download/validation leaves any previous entry untouched), so a newly
    # broken zip can never enter the cache.
    fetch_to_cache "$url" "$zip" _electron_zip_ok || die "Electron download failed: $url"
  else
    info "Using cached Electron: $zip"
  fi
  info "Unpacking Electron into $dest ..."
  unzip -q -o "$zip" -d "$dest" || die "Electron unzip failed (archive corrupt? delete $zip and retry)"
  chmod +x "$dest/electron" "$dest/chrome_crashpad_handler" 2>/dev/null || true
  [ -x "$dest/electron" ] || die "Electron binary missing after unpack"
}
