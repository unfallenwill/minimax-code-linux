#!/usr/bin/env bash
# asar extraction. We intentionally ship the app as an unpacked resources/app/
# directory rather than repacking an app.asar: it is more debuggable and Electron
# loads resources/app/ identically to resources/app.asar. (There is no macOS-style
# asar integrity binding on a stock Linux Electron build, so no repack is needed.)
# shellcheck shell=bash

# Cache @electron/asar once under $ROOT/build/asar-tools/ so the Node extractor
# (scripts/asar_extract.js) can `require()` it without touching the repo's
# package.json or paying the npx download cost on every run.
_asar_ensure_deps() {
  local root="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local pkg_dir="$root/build/asar-tools"
  if [ ! -d "$pkg_dir/node_modules/@electron/asar" ]; then
    info "Installing @electron/asar into $pkg_dir ..."
    mkdir -p "$pkg_dir"
    ( cd "$pkg_dir" && npm init -y >/dev/null 2>&1 \
      && npm install --no-audit --no-fund @electron/asar >/dev/null 2>&1 ) \
      || die "Failed to install @electron/asar"
  fi
  echo "$pkg_dir/node_modules"
}

# Extract $1/Resources/app.asar into $2, tolerantly merging app.asar.unpacked on
# top. $1 = app bundle Contents dir, $2 = destination app/ dir
asar_extract_app() {
  local contents="$1" out="$2"
  local asar="$contents/Resources/app.asar"
  local unpacked="$contents/Resources/app.asar.unpacked"
  [ -f "$asar" ] || die "app.asar not found at $asar"
  rm -rf "$out"; mkdir -p "$out"
  info "Extracting app.asar (tolerant mode) ..."
  local nm; nm="$(_asar_ensure_deps)"
  NODE_PATH="$nm" node "${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/asar_extract.js" \
    --asar "$asar" --out "$out" --unpacked-root "$unpacked" \
    || die "asar extract failed"
}
