#!/usr/bin/env bash
# Download and unpack the official Linux Electron runtime of a given version/arch
# directly into the install root, so its resources/ sits beside the MiniMax
# payload (resources/app, resources/resources/daemon).
# shellcheck shell=bash

# $1 = electron version, $2 = electron arch (x64|arm64), $3 = install root dir
electron_install() {
  local ver="$1" arch="$2" dest="$3"
  local asset="electron-v${ver}-linux-${arch}.zip"
  local url="https://github.com/${MMX_ELECTRON_REPO}/releases/download/v${ver}/${asset}"
  local cache="$MMX_CACHE_DIR/electron"
  mkdir -p "$cache" "$dest"
  local zip="$cache/$asset"
  if [ ! -s "$zip" ]; then
    info "Downloading Electron $ver linux-$arch ..."
    curl -fL --retry 3 --connect-timeout 30 -o "$zip" "$url" || die "Electron download failed: $url"
  else
    info "Using cached Electron: $zip"
  fi
  info "Unpacking Electron into $dest ..."
  unzip -q -o "$zip" -d "$dest" || die "Electron unzip failed"
  chmod +x "$dest/electron" "$dest/chrome_crashpad_handler" 2>/dev/null || true
  [ -x "$dest/electron" ] || die "Electron binary missing after unpack"
}
