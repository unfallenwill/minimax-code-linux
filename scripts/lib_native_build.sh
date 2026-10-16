#!/usr/bin/env bash
# Native-addons stage 3: addons that must be COMPILED for the target runtime
# because npm ships no usable Linux prebuild. Each builder works in an isolated
# temp directory so a failed compile never leaves a half-written tree in the
# app bundle, and degrades to a warning on failure.
#
#   native_install_better_sqlite3          npm install against Electron headers
#   native_install_node_pty_linux          node-gyp (pty.node) + g++ (spawn-helper)
#   native_build_session_transfer_client   Go cross-compile of our own client
#
# Companion modules: lib_native_strip.sh (offline strip/stub) and
# lib_native_pkgs.sh (platform packages fetched from npm).
# shellcheck shell=bash

# Reinstall better-sqlite3 as a full package built for the Electron runtime.
# The bundled copy is stripped (no source/binding.gyp) and its .node is darwin.
# We install in an ISOLATED temp project so npm does not try to resolve the app's
# own (partly private) dependency tree, then copy the built package into place.
# $1 = dir containing node_modules, $2 = electron version, $3 = npm arch
native_install_better_sqlite3() {
  local parent="$1" electron_ver="$2" arch="$3"
  local nm="$parent/node_modules"
  [ -d "$nm/better-sqlite3" ] || { info "no better-sqlite3 in $nm; skipping"; return 0; }
  local bver
  bver="$(_native_pkg_version "$nm/better-sqlite3")"
  [ -n "$bver" ] || bver="12.10.0"
  info "Reinstalling better-sqlite3@$bver for Electron $electron_ver (linux-$arch) ..."
  local work; work="$(mktemp -d)"
  local rc=0
  ( cd "$work" && npm init -y >/dev/null 2>&1 && \
    npm_config_runtime=electron npm_config_target="$electron_ver" \
    npm_config_target_arch="$arch" npm_config_build_from_source=false \
    npm install "better-sqlite3@$bver" --no-audit --no-fund --foreground-scripts ) >"$work/install.log" 2>&1 || rc=$?
  if [ $rc -eq 0 ] && [ -d "$work/node_modules/better-sqlite3" ]; then
    rm -rf "$nm/better-sqlite3"
    cp -a "$work/node_modules/better-sqlite3" "$nm/better-sqlite3"
    info "better-sqlite3 installed (linux-$arch electron build)"
  else
    warn "better-sqlite3 install failed (see $work/install.log); the app may fail to persist data"
  fi
  rm -rf "$work"
  return 0
}

# Drop the linux prebuilds for node-pty into the extracted tree. Upstream's
# macOS DMG includes only darwin-arm64 / darwin-x64 / win32-* prebuilds (and
# even those references are sometimes missing on disk); the asar header has no
# linux entries at all. node-pty's JS loader picks the right prebuild by
# process.platform + process.arch, so we only need to populate
# prebuilds/linux-{x64,arm64}/ without touching the rest of node-pty.
#
# node-pty@1.1.0 does not ship linux prebuilds on npm. We build them from
# source against the Electron headers:
#   - pty.node via node-gyp (needs Electron headers, downloads them)
#   - spawn-helper via g++ (plain POSIX, no Electron deps)
# binding.gyp only registers spawn-helper under OS=="mac", but the Linux fork
# path in pty.cc execvp()s it unconditionally — so we have to compile it
# ourselves.
# $1 = node_modules dir, $2 = npm arch (x64), $3 = electron version
native_install_node_pty_linux() {
  local nm="$1" arch="$2" electron_ver="$3"
  local main="$nm/node-pty"
  [ -d "$main" ] || { info "no node-pty in $nm; skipping"; return 0; }
  local ver
  ver="$(_native_pkg_version "$main")"
  [ -n "$ver" ] || ver="1.1.0"
  local want="linux-${arch}"
  local pty_target="$main/prebuilds/$want/pty.node"
  local helper_target="$main/prebuilds/$want/spawn-helper"
  if [ -f "$pty_target" ] && [ -x "$helper_target" ]; then
    info "node-pty $want prebuilds already present"
    return 0
  fi
  info "Building node-pty@$ver linux prebuilds ($want) for Electron $electron_ver ..."
  require_cmd g++ make python3
  local work; work="$(mktemp -d)"
  local rc=0
  ( cd "$work" && npm init -y >/dev/null 2>&1 \
    && npm install --no-audit --no-fund --no-save "node-pty@$ver" "node-addon-api" >/dev/null 2>&1 \
    && cd node_modules/node-pty \
    && npx --yes node-gyp rebuild --target="$electron_ver" --arch="$arch" \
         --dist-url=https://electronjs.org/headers --runtime=electron \
    >"$work/build.log" 2>&1 ) || rc=$?
  if [ $rc -ne 0 ] || [ ! -f "$work/node_modules/node-pty/build/Release/pty.node" ]; then
    warn "node-pty pty.node build failed (see $work/build.log); PTY support will be broken"
    rm -rf "$work"; return 0
  fi
  # spawn-helper: tiny standalone C++ binary (no Electron deps). node-pty's
  # binding.gyp only builds it on macOS; we compile it here for Linux.
  g++ -O2 -o "$work/spawn-helper" "$work/node_modules/node-pty/src/unix/spawn-helper.cc" \
    >>"$work/build.log" 2>&1 || {
      warn "spawn-helper compile failed (see $work/build.log); pty.fork() will fail"
      rm -rf "$work"; return 0
    }
  mkdir -p "$main/prebuilds/$want"
  cp -f "$work/node_modules/node-pty/build/Release/pty.node" "$pty_target"
  cp -f "$work/spawn-helper" "$helper_target"
  chmod 0755 "$helper_target"
  info "node-pty $want prebuilds built (pty.node + spawn-helper)"
  rm -rf "$work"
  return 0
}

# Build the Linux session-transfer client from source.
#
# The DMG ships resources/resources/session-transfer/darwin-x64/ only: a Mach-O
# binary that cannot execute on Linux, and upstream publishes no Linux build.
# local-runtime-v2 looks for `session-transfer/<platform>-<arch>/<binary>` under
# process.resourcesPath (resolveBundledSessionTransferClient), so without a
# linux-x64 entry it simply deletes MAVIS_SESSION_TRANSFER_CLIENT and the
# session-handoff transfer capability stays absent.
#
# native/session-transfer-client/ in this repo is a from-scratch Go
# implementation of the same stdin/stdout NDJSON protocol and relay API. We
# compile it for the target arch so x86_64 packaging works from any host.
# $1 = resources/resources dir, $2 = npm arch (x64)
native_build_session_transfer_client() {
  local res_dir="$1" arch="$2"
  # ROOT is exported by install.sh but not when this library is sourced
  # directly, and the build runs under `set -u`.
  local root="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local src="$root/native/session-transfer-client"
  [ -d "$src" ] || { warn "session-transfer client sources missing at $src; skipping"; return 0; }
  require_cmd go

  local goos="linux"
  local goarch
  case "$arch" in
    x64|amd64) goarch="amd64" ;;
    *) warn "session-transfer client: unsupported arch '$arch'; skipping"; return 0 ;;
  esac

  local out_dir="$res_dir/session-transfer/linux-$arch"
  local binary="$out_dir/mavis-session-transfer-client"
  # A stale binary from a previous build must not be reused after a source change.
  rm -f "$binary"
  mkdir -p "$out_dir"

  info "Building session-transfer client for linux-$goarch ..."
  local work rc=0
  work="$(mktemp -d)"
  # Build from a copy so a failed compile never leaves a half-written tree and
  # GOFLAGS from the caller's environment cannot redirect the build.
  cp -a "$src/." "$work/"
  ( cd "$work" && CGO_ENABLED=0 GOOS="$goos" GOARCH="$goarch" \
      go build -trimpath -ldflags="-s -w" \
      -o "$binary" . ) >"$work/build.log" 2>&1 || rc=$?
  if [ $rc -ne 0 ] || [ ! -x "$binary" ]; then
    warn "session-transfer client build failed (see $work/build.log); session handoff transfers will be unavailable"
    rm -f "$binary"
    rm -rf "$work"
    return 0
  fi
  rm -rf "$work"
  chmod 0755 "$binary"
  info "session-transfer client built for linux-$goarch"
}
