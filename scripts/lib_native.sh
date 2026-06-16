#!/usr/bin/env bash
# Native addon handling for the MiniMax Code Linux build.
#
# Survey of the bundled native modules (verified against Electron 38.3.0 = Node
# 22, ABI 139):
#   - better-sqlite3 (GUI)       : shipped stripped (no binding.gyp) + darwin
#                                  .node. REINSTALL a full copy built for Electron.
#   - node-screenshots (GUI)     : only a darwin platform package is bundled.
#                                  SWAP in the linux-<libc> platform package
#                                  (N-API, ABI-stable, no rebuild).
#   - @nut-tree/libnut-linux     : N-API prebuild, LOAD OK -> untouched.
#   - fs-native-extensions       : N-API prebuild, LOAD OK -> untouched.
#   - @nut-tree/node-mac-permissions : macOS-only -> STUB with a no-op shim.
#   - Squirrel / Mantle          : live in Contents/Frameworks, never copied -> N/A.
#
# Applied to both the GUI node_modules and the daemon node_modules.
# shellcheck shell=bash

# Remove darwin/win32-only native packages from a node_modules tree.
# $1 = node_modules dir
native_strip_macos() {
  local nm="$1"
  [ -d "$nm" ] || return 0
  rm -rf \
    "$nm"/node-screenshots-darwin-* \
    "$nm"/node-screenshots-win32-* \
    "$nm"/@nut-tree/node-mac-permissions \
    "$nm"/@nut-tree/libnut-darwin \
    "$nm"/@nut-tree/libnut-win32 \
    2>/dev/null || true
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

# Install the Linux platform package for node-screenshots (napi-rs, ABI-stable).
# $1 = node_modules dir, $2 = npm arch (x64|arm64)
native_swap_screenshots() {
  local nm="$1" arch="$2"
  local main="$nm/node-screenshots"
  [ -d "$main" ] || return 0
  local libc="${MMX_LIBC:-gnu}"                       # gnu (glibc) | musl (Alpine)
  local pkg="node-screenshots-linux-${arch}-${libc}"
  [ -d "$nm/$pkg" ] && { info "$pkg already present"; return 0; }
  local ver
  ver="$(node -e 'try{console.log(require(process.argv[1]+"/package.json").version)}catch(e){console.log("")}' "$main" 2>/dev/null || true)"
  [ -n "$ver" ] || ver="0.2.8"
  info "Installing $pkg@$ver ..."
  # npm pack writes the tarball into $nm and prints only the basename.
  local tgz
  tgz="$( cd "$nm" && npm pack "$pkg@$ver" 2>/dev/null | tail -1 || true )"
  if [ -n "$tgz" ] && [ -s "$nm/$tgz" ]; then
    rm -rf "$nm/$pkg"; mkdir -p "$nm/$pkg"
    tar -xzf "$nm/$tgz" -C "$nm/$pkg" --strip-components=1
    rm -f "$nm/$tgz"
    info "Installed $pkg"
  else
    rm -f "$nm"/*.tgz 2>/dev/null || true
    warn "Could not fetch $pkg@$ver; screenshot capture may be unavailable"
  fi
}

# Replace the bundled (darwin) opencode agent binary with the Linux build.
# opencode is the OpenCode CLI (sst/opencode), shipped as per-platform npm
# packages (opencode-linux-x64, opencode-linux-arm64, ...-musl). The macOS DMG
# bundles only the darwin build, which fails to spawn on Linux (EACCES/ENOEXEC)
# — this is what breaks sending messages, since every agent runs `opencode serve`.
# $1 = the resources/resources dir, $2 = npm arch (x64|arm64)
native_install_opencode() {
  local res_dir="$1" arch="$2"
  local bin="$res_dir/opencode/opencode"
  [ -f "$bin" ] || { info "no bundled opencode; skipping"; return 0; }
  if file "$bin" | grep -q "ELF"; then info "opencode already Linux ELF; skipping"; return 0; fi
  # opencode is a Bun-compiled binary; its version is embedded as
  # "vX.Y.Z (<githex>)" (the bun version banner). That pattern is unambiguous,
  # unlike bare vX.Y.Z which also matches bundled sub-dependency versions.
  local ver
  ver="$(strings "$bin" 2>/dev/null | grep -aoE "v[0-9]+\.[0-9]+\.[0-9]+ \([0-9a-f]+\)" | head -1 | grep -oE "[0-9]+\.[0-9]+\.[0-9]+")"
  [ -n "$ver" ] || ver="1.3.13"
  local libc="${MMX_LIBC:-gnu}"
  local pkg="opencode-linux-${arch}"
  [ "$libc" = musl ] && pkg="opencode-linux-${arch}-musl"
  info "Installing $pkg@$ver (replacing darwin opencode) ..."
  local work; work="$(mktemp -d)"
  local tgz
  tgz="$( cd "$work" && npm pack "$pkg@$ver" 2>/dev/null | tail -1 || true )"
  if [ -n "$tgz" ] && [ -s "$work/$tgz" ]; then
    tar -xzf "$work/$tgz" -C "$work"
    local src="$work/package/bin/opencode"
    if [ -f "$src" ]; then
      cp -f "$src" "$bin"
      chmod 0755 "$bin"
      info "opencode replaced with Linux build"
    else
      warn "opencode binary not found inside $pkg tarball"
    fi
  else
    warn "Could not fetch $pkg@$ver; agent messaging will not work"
  fi
  rm -rf "$work"
}

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
  bver="$(node -e 'try{console.log(require(process.argv[1]+"/package.json").version)}catch(e){console.log("")}' "$nm/better-sqlite3" 2>/dev/null || true)"
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
}
