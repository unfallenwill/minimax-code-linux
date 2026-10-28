#!/usr/bin/env bash
# Build a runnable Linux MiniMax Code app from an official macOS DMG.
#
#   ./install.sh --dmg "MiniMax Code-3.0.43.dmg" --install-dir build/minimax-code
#
# Pipeline: extract DMG -> stage resources/ -> extract app.asar -> process native
# addons (GUI) -> install matching Linux Electron -> write start.sh.
#
# Safety: arguments and the output directory are validated before any
# destructive step runs, the build happens in a same-filesystem staging
# directory next to --install-dir, and the previous installation is replaced
# only after the staged build is complete (publish_staged_dir). A failed run
# cleans up its staging dir and restores the previous install best-effort (the
# publish step is two renames, not an atomic exchange).
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib_common.sh
. "$SCRIPT_DIR/scripts/lib_common.sh"
# shellcheck source=scripts/lib_dmg.sh
. "$SCRIPT_DIR/scripts/lib_dmg.sh"
# shellcheck source=scripts/lib_asar.sh
. "$SCRIPT_DIR/scripts/lib_asar.sh"
# shellcheck source=scripts/lib_native_strip.sh
. "$SCRIPT_DIR/scripts/lib_native_strip.sh"
# shellcheck source=scripts/lib_native_pkgs.sh
. "$SCRIPT_DIR/scripts/lib_native_pkgs.sh"
# shellcheck source=scripts/lib_native_build.sh
. "$SCRIPT_DIR/scripts/lib_native_build.sh"
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
                       The build runs in a sibling staging directory; an
                       existing installation is replaced only on success.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dmg)
      [ $# -ge 2 ] || die "Option --dmg requires a path argument"
      DMG="$2"; shift 2 ;;
    --install-dir)
      [ $# -ge 2 ] || die "Option --install-dir requires a directory argument"
      INSTALL_DIR="$2"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *) die "Unknown argument: $1 (try --help)" ;;
  esac
done

# Validate everything that guards destructive operations BEFORE any work runs:
# no extraction, no download, no rm -rf may happen on a refused path.
assert_safe_output_dir "$INSTALL_DIR" "--install-dir"
if [ -n "$DMG" ] && [ ! -f "$DMG" ]; then
  die "--dmg: file not found: $DMG"
fi

require_cmd curl perl node npx python3 unzip tar file npm
require_7z   # 7zz or 7z >= MMX_7Z_MIN_VERSION; XZ-compressed DMGs need 24.01+
resolve_arch "$ARCH"

WORK="$(mktemp -d)"
STAGING=""
trap 'rm -rf "$WORK" ${STAGING:+"$STAGING"}' EXIT

info "==> Resolving DMG"
DMG_PATH="$(dmg_resolve "$DMG")"

info "==> Extracting DMG"
APP="$(dmg_extract "$DMG_PATH" "$WORK/dmg")"
CONTENTS="$APP/Contents"

info "==> Detecting versions"
ELECTRON_VERSION="$(dmg_detect_electron "$APP")"
APP_VERSION="$(dmg_app_version "$APP")"
info "MiniMax Code $APP_VERSION / Electron $ELECTRON_VERSION / target linux-$MMX_ELECTRON_ARCH"

# Build in a staging directory that is a sibling of the final install dir (so
# publishing is a same-filesystem rename and a failed build is very unlikely to
# touch an existing installation; the publish itself is two renames, not an
# atomic exchange, and restores the old tree best-effort on failure).
FINAL_DIR="$(readlink -m "$INSTALL_DIR")"
PARENT_DIR="$(dirname "$FINAL_DIR")"
mkdir -p "$PARENT_DIR"
STAGING="$(mktemp -d "$PARENT_DIR/.minimax-code-staging.XXXXXX")" \
  || die "Cannot create staging directory in $PARENT_DIR"

info "==> Staging app resources"
info "  staging: $STAGING"
info "  target:  $FINAL_DIR (replaced only on success)"
# Mirror Contents/Resources so every path the app resolves via
# process.resourcesPath (mcode-tools, pptx-core, bundled runtime resources) is intact.
mkdir -p "$STAGING/resources"
cp -a "$CONTENTS/Resources/." "$STAGING/resources/"
rm -f "$STAGING/resources/app.asar"

# 7z extracts macOS extended-attribute / code-signature sidecars as literal
# files named "<file>:com.apple.provenance", "<file>:com.apple.cs.CodeDirectory",
# etc. They are meaningless off macOS, and some subsystems actively reject a
# resource directory that contains undeclared files -- mcode-tools' validator
# (validateEmbeddedResourceFiles) requires the directory to contain exactly the
# files its manifest lists, so these leftovers made the connector integration
# fail with "mcode-tools embedded output must contain only declared resources".
# Strip them everywhere we copied from the DMG.
info "==> Stripping macOS metadata sidecars"
find "$STAGING/resources" -name '*:com.apple.*' -type f -delete 2>/dev/null || true
find "$STAGING/resources" -name '*:com.apple.*' -type l -delete 2>/dev/null || true

info "==> Extracting app.asar -> resources/app"
asar_extract_app "$CONTENTS" "$STAGING/resources/app"
# app.asar.unpacked was copied wholesale above; the merge into app/ already
# covered its contents, so drop the duplicate directory.
rm -rf "$STAGING/resources/app.asar.unpacked"

info "==> Applying Linux adaptation patches"
node "$SCRIPT_DIR/scripts/patch_linux.js" "$STAGING/resources/app" "$MMX_PKG_NAME"

info "==> Verifying bundled runtime resources"
# Upstream moves these in/out between releases and gates their loading on
# app.isPackaged (patched to true in patch_linux.js), so a missing directory is
# a SILENT feature loss, not a build failure. Warn loudly instead.
#   mcode-tools/   connector integration; without it startup reports
#                  "mcode-tools development resource preparation failed"
#   pptx-core/     WASM runtime for pptx rendering; without runtime.json the
#                  protocol handler registers with a null runtime root
for _dir in mcode-tools pptx-core; do
  if [ -d "$STAGING/resources/resources/$_dir" ]; then
    info "  present: resources/$_dir"
  else
    warn "missing: resources/$_dir (upstream ships a different layout in this version?)"
  fi
done
if [ -f "$STAGING/resources/resources/pptx-core/runtime.json" ]; then
  info "  present: resources/pptx-core/runtime.json"
else
  warn "missing: resources/pptx-core/runtime.json (pptx rendering will be disabled)"
fi

GUI_ROOT="$STAGING/resources/app"

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

info "==> Replacing bundled agent binaries for Linux"
# session-transfer ships as a darwin-x64 Mach-O binary with no Linux equivalent
# upstream; build our own so session handoff can transfer sessions on Linux.
native_build_session_transfer_client "$STAGING/resources/resources" "$MMX_NPM_ARCH"

# The DMG ships only @trycua/cua-driver-darwin-*, but upstream also publishes a
# Linux build of the same driver. Pull it from npm so the computer-use skill can
# load its native library instead of missing it entirely.
native_install_cua_driver "$GUI_ROOT/node_modules" "$MMX_NPM_ARCH"

info "==> Installing Linux Electron $ELECTRON_VERSION (linux-$MMX_ELECTRON_ARCH)"
electron_install "$ELECTRON_VERSION" "$MMX_ELECTRON_ARCH" "$STAGING"

info "==> Writing launcher"
# start.sh lives at the install root, next to the electron binary and resources/.
cp "$SCRIPT_DIR/launcher/start.sh.template" "$STAGING/start.sh"
chmod +x "$STAGING/start.sh" "$STAGING/electron" 2>/dev/null || true

info "==> Writing build-info.json"
cat > "$STAGING/build-info.json" <<EOF
{
  "product": "MiniMax Code",
  "upstream_version": "$APP_VERSION",
  "electron_version": "$ELECTRON_VERSION",
  "target_arch": "linux-$MMX_ELECTRON_ARCH",
  "app_id": "$MMX_APP_ID",
  "unofficial": true
}
EOF

info "==> Publishing staged build -> $FINAL_DIR"
publish_staged_dir "$STAGING" "$FINAL_DIR" \
  || die "Publish failed; any previous installation at $FINAL_DIR is untouched"
info "==> Done. Launch with: $FINAL_DIR/start.sh"
