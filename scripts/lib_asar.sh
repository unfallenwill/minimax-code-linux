#!/usr/bin/env bash
# asar extraction. We intentionally ship the app as an unpacked resources/app/
# directory rather than repacking an app.asar: it is more debuggable and Electron
# loads resources/app/ identically to resources/app.asar. (There is no macOS-style
# asar integrity binding on a stock Linux Electron build, so no repack is needed.)
# shellcheck shell=bash

# Extract $1/Resources/app.asar into $2 and overlay app.asar.unpacked on top.
# $1 = app bundle Contents dir, $2 = destination app/ dir
asar_extract_app() {
  local contents="$1" out="$2"
  local asar="$contents/Resources/app.asar"
  local unpacked="$contents/Resources/app.asar.unpacked"
  [ -f "$asar" ] || die "app.asar not found at $asar"
  rm -rf "$out"; mkdir -p "$out"
  info "Extracting app.asar ..."
  npx --yes -p @electron/asar -- asar extract "$asar" "$out" || die "asar extract failed"
  if [ -d "$unpacked" ]; then
    info "Merging app.asar.unpacked (native addons) ..."
    cp -a "$unpacked/." "$out/" 2>/dev/null || true
  fi
}
