#!/usr/bin/env bash
# Native-addons stage 2: platform packages that the macOS DMG omits and that
# upstream publishes on npm. Each installer reads the version to pin from the
# bundled main package (so SDK and native binary can never drift), skips when
# the Linux package is already present, and degrades to a warning (never a
# hard failure) when the fetch fails.
#
# Shared helpers:
#   _native_pkg_version   read a package's version from its package.json
#   _native_fetch_pkg     `npm pack` + extract into place, atomically enough
#                         that a failed fetch never leaves a partial package
#
# Companion modules: lib_native_strip.sh (offline strip/stub) and
# lib_native_build.sh (addons compiled from source).
# shellcheck shell=bash

# Read the version of the npm package at <dir> from its package.json.
# Echoes the version, or the empty string if it cannot be read.
_native_pkg_version() {
  node -e 'try{console.log(require(process.argv[1]+"/package.json").version)}catch(e){console.log("")}' "$1" 2>/dev/null || true
}

# Fetch an npm package tarball with `npm pack` and extract it into <dest>.
#   _native_fetch_pkg <name@version> <dest-dir> <consequence-note>
# The download happens in an isolated temp dir (never inside the target
# node_modules) and <dest> is removed again on any failure, so a broken fetch
# never leaves a half-populated package behind. Warns (with <note>) and
# returns non-zero on failure; never dies — callers degrade gracefully.
_native_fetch_pkg() {
  local spec="$1" dest="$2" note="$3"
  local work tgz rc=1
  work="$(mktemp -d)"
  tgz="$( cd "$work" && npm pack "$spec" 2>/dev/null | tail -1 || true )"
  if [ -n "$tgz" ] && [ -s "$work/$tgz" ]; then
    mkdir -p "$dest"
    if tar -xzf "$work/$tgz" -C "$dest" --strip-components=1; then
      rc=0
    fi
  fi
  rm -rf "$work"
  if [ "$rc" -ne 0 ]; then
    rm -rf "$dest"
    warn "Could not fetch $spec; $note"
  fi
  return "$rc"
}

# Install the Linux platform package for node-screenshots (napi-rs, ABI-stable).
# The DMG bundles only a darwin platform package; swap in the linux-<libc> one.
# $1 = node_modules dir, $2 = npm arch (x64)
native_swap_screenshots() {
  local nm="$1" arch="$2"
  local main="$nm/node-screenshots"
  [ -d "$main" ] || return 0
  local libc="${MMX_LIBC:-gnu}"                       # gnu (glibc) | musl (Alpine)
  local pkg="node-screenshots-linux-${arch}-${libc}"
  [ -d "$nm/$pkg" ] && { info "$pkg already present"; return 0; }
  local ver
  ver="$(_native_pkg_version "$main")"
  [ -n "$ver" ] || ver="0.2.8"
  info "Installing $pkg@$ver ..."
  if _native_fetch_pkg "$pkg@$ver" "$nm/$pkg" "screenshot capture may be unavailable"; then
    info "Installed $pkg"
  fi
  return 0
}

# Install the Linux platform package for @mariozechner/clipboard. Upstream ships
# only the darwin platform subpackage (clipboard-darwin-arm64 + darwin-universal)
# in the asar, so require('@mariozechner/clipboard') fails to find a binary on
# Linux. The Linux variant is optionalDependencies in the main package, so
# pull it from npm at the bundled main package's version.
# $1 = node_modules dir, $2 = npm arch (x64)
native_install_mariozechner_clipboard() {
  local nm="$1" arch="$2"
  local main="$nm/@mariozechner/clipboard"
  [ -d "$main" ] || { info "no @mariozechner/clipboard in $nm; skipping"; return 0; }
  local ver
  ver="$(_native_pkg_version "$main")"
  [ -n "$ver" ] || ver="0.3.9"
  local libc="${MMX_LIBC:-gnu}"
  local pkg="@mariozechner/clipboard-linux-${arch}-${libc}"
  [ -d "$nm/$pkg" ] && { info "$pkg already present"; return 0; }
  info "Installing $pkg@$ver ..."
  if _native_fetch_pkg "$pkg@$ver" "$nm/$pkg" "clipboard integration may be unavailable"; then
    info "Installed $pkg"
  fi
  return 0
}

# Install the Linux platform package for @vscode/ripgrep. The DMG bundles only
# @vscode/ripgrep-darwin-{x64,arm64}; the linux binary has to come from npm.
# We pin to the same version that ships in the asar to keep any API surface in
# sync (@vscode/ripgrep is a thin wrapper that just spawns the bin/rg binary).
# $1 = node_modules dir, $2 = npm arch (x64)
native_install_vscode_ripgrep() {
  local nm="$1" arch="$2"
  local main="$nm/@vscode/ripgrep"
  [ -d "$main" ] || { info "no @vscode/ripgrep in $nm; skipping"; return 0; }
  local ver
  ver="$(_native_pkg_version "$main")"
  [ -n "$ver" ] || ver="1.18.0"
  local pkg="@vscode/ripgrep-linux-${arch}"
  [ -d "$nm/$pkg" ] && { info "$pkg already present"; return 0; }
  info "Installing $pkg@$ver ..."
  if _native_fetch_pkg "$pkg@$ver" "$nm/$pkg" "ripgrep-based search may be unavailable"; then
    info "Installed $pkg"
  fi
  return 0
}

# Install the Linux Cua Driver native package used by the computer-use skill.
#
# The macOS DMG ships only @trycua/cua-driver-darwin-{x64,arm64}: npm prunes
# optionalDependencies to the host platform, so the Linux build is absent even
# though upstream PUBLISHES it. cua-driver's own optionalDependencies list all
# six platforms (linux-x64-gnu / linux-arm64-gnu / linux-*-musl included), and
# its resolveLibPath() already derives `linux-<arch>-<libc>` from
# process.platform + glibc, so no code change is needed on the SDK side -- the
# only missing piece is the native library itself.
#
# We pin the version to whatever the bundled darwin package declares, so the
# SDK and the native lib can never drift apart.
# $1 = node_modules dir, $2 = npm arch (x64)
native_install_cua_driver() {
  local nm="$1" arch="$2"
  local sdk="$nm/@trycua/cua-driver"
  [ -d "$sdk" ] || { info "no @trycua/cua-driver in $nm; skipping"; return 0; }

  local ver
  ver="$(_native_pkg_version "$sdk")"
  [ -n "$ver" ] || ver="0.22.1"

  local libc="${MMX_LIBC:-gnu}"
  local pkg="cua-driver-linux-${arch}-${libc}"
  local dir="$nm/@trycua/$pkg"
  if [ -f "$dir/libcua_driver_sdk.so" ] && [ -f "$dir/cua_driver_node_runtime.node" ]; then
    info "$pkg already present"; return 0
  fi

  info "Installing @trycua/$pkg@$ver (computer-use native driver) ..."
  local work
  work="$(mktemp -d)"
  if _native_fetch_pkg "@trycua/$pkg@$ver" "$work/package" "computer-use will be unavailable"; then
    if [ -f "$work/package/libcua_driver_sdk.so" ] && [ -f "$work/package/cua_driver_node_runtime.node" ]; then
      rm -rf "$dir"; mkdir -p "$dir"
      cp -a "$work/package/." "$dir/"
      chmod 0755 "$dir/libcua_driver_sdk.so" "$dir/cua_driver_node_runtime.node"
      info "@trycua/$pkg installed"
    else
      warn "@trycua/$pkg tarball is missing the expected native files"
    fi
  fi
  rm -rf "$work"
  return 0
}
