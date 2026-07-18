#!/usr/bin/env bash
# Build a runnable Linux MiniMax Code app from an official macOS DMG.
#
#   ./install.sh --dmg "MiniMax Code-3.0.43.dmg" --install-dir build/minimax-code
#
# Pipeline: extract DMG -> stage resources/ -> extract app.asar -> process native
# addons (GUI + daemon) -> install matching Linux Electron -> write start.sh.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib_common.sh
. "$SCRIPT_DIR/scripts/lib_common.sh"
# shellcheck source=scripts/lib_dmg.sh
. "$SCRIPT_DIR/scripts/lib_dmg.sh"
# shellcheck source=scripts/lib_asar.sh
. "$SCRIPT_DIR/scripts/lib_asar.sh"
# shellcheck source=scripts/lib_native.sh
. "$SCRIPT_DIR/scripts/lib_native.sh"
# shellcheck source=scripts/lib_electron.sh
. "$SCRIPT_DIR/scripts/lib_electron.sh"

DMG=""
INSTALL_DIR="$SCRIPT_DIR/build/minimax-code"
ARCH="x64"   # internal default; only x64 is supported

usage() {
  cat <<EOF
Usage: $0 --dmg <path> [--install-dir <dir>]
  --dmg <path>         macOS DMG to convert (or set MMX_UPSTREAM_DMG_URL)
  --install-dir <dir>  output dir (default: build/minimax-code)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dmg)         DMG="$2"; shift 2 ;;
    --install-dir) INSTALL_DIR="$2"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *) die "Unknown argument: $1 (try --help)" ;;
  esac
done

require_cmd 7z curl perl node npx python3 unzip tar file strings npm
resolve_arch "$ARCH"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

info "==> Resolving DMG"
DMG_PATH="$(dmg_resolve "$DMG")"

info "==> Extracting DMG"
APP="$(dmg_extract "$DMG_PATH" "$WORK/dmg")"
CONTENTS="$APP/Contents"

info "==> Detecting versions"
ELECTRON_VERSION="$(dmg_detect_electron "$APP")"
APP_VERSION="$(dmg_app_version "$APP")"
info "MiniMax Code $APP_VERSION / Electron $ELECTRON_VERSION / target linux-$MMX_ELECTRON_ARCH"

info "==> Staging app resources -> $INSTALL_DIR"
rm -rf "$INSTALL_DIR"; mkdir -p "$INSTALL_DIR/resources"
# Mirror Contents/Resources so every path the app resolves via
# process.resourcesPath (incl. the daemon at resources/resources/daemon) is intact.
cp -a "$CONTENTS/Resources/." "$INSTALL_DIR/resources/"
rm -f "$INSTALL_DIR/resources/app.asar"

info "==> Extracting app.asar -> resources/app"
asar_extract_app "$CONTENTS" "$INSTALL_DIR/resources/app"
# app.asar.unpacked was copied wholesale above; the merge into app/ already
# covered its contents, so drop the duplicate directory.
rm -rf "$INSTALL_DIR/resources/app.asar.unpacked"

info "==> Applying Linux adaptation patches"
node "$SCRIPT_DIR/scripts/patch_linux.js" "$INSTALL_DIR/resources/app" "$MMX_PKG_NAME"

GUI_ROOT="$INSTALL_DIR/resources/app"
DAEMON_ROOT="$INSTALL_DIR/resources/resources/daemon"

info "==> Processing native modules (GUI)"
native_swap_screenshots     "$GUI_ROOT/node_modules" "$MMX_NPM_ARCH"
native_install_better_sqlite3 "$GUI_ROOT" "$ELECTRON_VERSION" "$MMX_NPM_ARCH"
native_strip_macos          "$GUI_ROOT/node_modules"
native_stub_mac_permissions "$GUI_ROOT/node_modules"
# Add the Linux-native platform packages that the DMG omits: @mariozechner/clipboard
# and @vscode/ripgrep only ship darwin subpackages, and node-pty has no Linux
# prebuilds at all in the upstream asar. Pull each from npm, pinned to whatever
# version the upstream main package declares.
native_install_mariozechner_clipboard "$GUI_ROOT/node_modules" "$MMX_NPM_ARCH"
native_install_vscode_ripgrep         "$GUI_ROOT/node_modules" "$MMX_NPM_ARCH"
native_install_node_pty_linux         "$GUI_ROOT/node_modules" "$MMX_NPM_ARCH" "$ELECTRON_VERSION"

if [ -d "$DAEMON_ROOT" ]; then
  info "==> Processing native modules (daemon)"
  native_strip_macos          "$DAEMON_ROOT/node_modules"
  native_stub_mac_permissions "$DAEMON_ROOT/node_modules"
fi

info "==> Replacing bundled agent binaries for Linux"
# The macOS DMG bundles only the darwin opencode (the agent runtime). Without a
# Linux build, daemon can't spawn agents -> sending messages silently fails.
native_install_opencode "$INSTALL_DIR/resources/resources" "$MMX_NPM_ARCH"

info "==> Installing Linux Electron $ELECTRON_VERSION (linux-$MMX_ELECTRON_ARCH)"
electron_install "$ELECTRON_VERSION" "$MMX_ELECTRON_ARCH" "$INSTALL_DIR"

info "==> Writing launcher"
# start.sh lives at the install root, next to the electron binary and resources/.
cp "$SCRIPT_DIR/launcher/start.sh.template" "$INSTALL_DIR/start.sh"
chmod +x "$INSTALL_DIR/start.sh" "$INSTALL_DIR/electron" 2>/dev/null || true

info "==> Writing build-info.json"
cat > "$INSTALL_DIR/build-info.json" <<EOF
{
  "product": "MiniMax Code",
  "upstream_version": "$APP_VERSION",
  "electron_version": "$ELECTRON_VERSION",
  "target_arch": "linux-$MMX_ELECTRON_ARCH",
  "app_id": "$MMX_APP_ID",
  "unofficial": true
}
EOF

info "==> Done. Launch with: $INSTALL_DIR/start.sh"
