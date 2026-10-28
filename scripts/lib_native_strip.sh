#!/usr/bin/env bash
# Native-addons stage 1 (offline): strip macOS/Windows-only packages from a
# node_modules tree and stub the one macOS-only module that has no Linux
# equivalent. Pure filesystem work — no network, no npm. Applied to the GUI
# node_modules tree.
#
# Companion modules:
#   scripts/lib_native_pkgs.sh   platform packages fetched from npm
#   scripts/lib_native_build.sh  addons compiled from source
#
# Survey of the bundled native modules (verified against Electron 38.3.0 =
# Node 22, ABI 139):
#   - @nut-tree/libnut-linux     : N-API prebuild, LOAD OK -> untouched.
#   - fs-native-extensions       : N-API prebuild, LOAD OK -> untouched.
#   - @nut-tree/node-mac-permissions : macOS-only TCC API -> STUB (below).
#   - Squirrel / Mantle          : live in Contents/Frameworks, never copied -> N/A.
# shellcheck shell=bash

# Remove darwin/win32-only native packages from a node_modules tree.
# $1 = node_modules dir
native_strip_macos() {
  local nm="$1"
  [ -d "$nm" ] || return 0
  rm -rf \
    "$nm"/node-screenshots-darwin-* \
    "$nm"/node-screenshots-win32-* \
    "$nm"/@mariozechner/clipboard-darwin-* \
    "$nm"/@mariozechner/clipboard-win32-* \
    "$nm"/@vscode/ripgrep-darwin-* \
    "$nm"/@vscode/ripgrep-win32-* \
    "$nm"/@nut-tree/node-mac-permissions \
    "$nm"/@nut-tree/libnut-darwin \
    "$nm"/@nut-tree/libnut-win32 \
    2>/dev/null || true
  # node-pty ships prebuilds for every platform; we only want the linux ones.
  if [ -d "$nm/node-pty/prebuilds" ]; then
    find "$nm/node-pty/prebuilds" -mindepth 1 -maxdepth 1 \
      ! -name 'linux-*' -exec rm -rf {} + 2>/dev/null || true
  fi
}

# Replace @nut-tree/node-mac-permissions with a no-op shim so require() resolves.
# (macOS TCC permission API has no Linux equivalent; return "granted" for all.)
# $1 = node_modules dir
native_stub_mac_permissions() {
  local nm="$1"
  local pkg="$nm/@nut-tree/node-mac-permissions"
  rm -rf "$pkg"; mkdir -p "$pkg"
  cat > "$pkg/package.json" <<'JSON'
{ "name": "@nut-tree/node-mac-permissions", "version": "0.0.0-shim", "main": "index.js" }
JSON
  cat > "$pkg/index.js" <<'JS'
// No-op shim (MiniMax Code Linux build). Any method call returns 0 (granted);
// any property access returns a callable, so callers never throw.
module.exports = new Proxy(function () { return 0; }, {
  get: () => function () { return 0; },
  apply: () => 0,
});
JS
}
