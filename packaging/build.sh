#!/usr/bin/env bash
# Build .deb and .rpm for MiniMax Code (one arch) from a macOS DMG.
#
#   PRODUCT_VERSION=3.0.43 DMG="MiniMax Code-3.0.43.dmg" ./packaging/build.sh
#
# Env:
#   PRODUCT_VERSION  upstream version (auto-detected from the DMG if unset)
#   DMG              path to a local DMG
#   DMG_URL          URL to download the DMG from (used if DMG is unset)
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib_common.sh
. "$ROOT/scripts/lib_common.sh"

ARCH="${ARCH:-x64}"
DMG="${DMG:-}"
DMG_URL="${DMG_URL:-}"
PRODUCT_VERSION="${PRODUCT_VERSION:-}"
require_cmd curl nfpm perl node

resolve_arch "$ARCH"   # exports MMX_DEB_ARCH, MMX_RPM_ARCH, MMX_NPM_ARCH, MMX_ELECTRON_ARCH

# ---- Resolve the DMG --------------------------------------------------------
if [ -z "$DMG" ]; then
  [ -n "$DMG_URL" ] || die "Provide DMG=<path> or DMG_URL=<url>."
  mkdir -p "$MMX_CACHE_DIR"
  DMG="$MMX_CACHE_DIR/minimax-code.dmg"
  info "Downloading DMG from $DMG_URL ..."
  curl -fL --retry 3 -o "$DMG" "$DMG_URL"
fi
[ -f "$DMG" ] || die "DMG not found: $DMG"

BUILD="$ROOT/build"
DIST="$ROOT/dist"
PAYLOAD="$BUILD/payload"
mkdir -p "$DIST" "$BUILD/scripts"

# ---- Build the runnable Linux app -------------------------------------------
info "==> Building app (arch=$ARCH) from $DMG"
rm -rf "$PAYLOAD"
"$ROOT/install.sh" --dmg "$DMG" --install-dir "$PAYLOAD" --arch "$ARCH"

# ---- Version ----------------------------------------------------------------
if [ -z "$PRODUCT_VERSION" ]; then
  PRODUCT_VERSION="$(node -e "console.log(require('$PAYLOAD/build-info.json').upstream_version)")"
fi
ELECTRON_VERSION="$(node -e "console.log(require('$PAYLOAD/build-info.json').electron_version)")"
info "Packaging MiniMax Code $PRODUCT_VERSION (Electron $ELECTRON_VERSION) $MMX_DEB_ARCH/$MMX_RPM_ARCH"

# ---- Render templates (perl ${VAR}) -----------------------------------------
render() { perl -pe 's/\$\{(\w+)\}/defined $ENV{$1} ? $ENV{$1} : ""/ge' "$1" > "$2"; }

PKG_NAME="$MMX_PKG_NAME" \
DISPLAY="$MMX_DISPLAY" WMCLASS="$MMX_WMCLASS" \
INSTALL_PREFIX="$MMX_INSTALL_PREFIX" \
VERSION="$PRODUCT_VERSION" ELECTRON_VERSION="$ELECTRON_VERSION" \
NFPM_ARCH="$MMX_DEB_ARCH" \
  render "$ROOT/packaging/templates/nfpm.yaml.tmpl" "$BUILD/nfpm.yaml"
PKG_NAME="$MMX_PKG_NAME" DISPLAY="$MMX_DISPLAY" WMCLASS="$MMX_WMCLASS" INSTALL_PREFIX="$MMX_INSTALL_PREFIX" \
  render "$ROOT/packaging/templates/desktop.tmpl" "$BUILD/$MMX_PKG_NAME.desktop"
PKG_NAME="$MMX_PKG_NAME" INSTALL_PREFIX="$MMX_INSTALL_PREFIX" \
  render "$ROOT/packaging/templates/wrapper.tmpl" "$BUILD/wrapper"
INSTALL_PREFIX="$MMX_INSTALL_PREFIX" \
  render "$ROOT/packaging/templates/postinst.tmpl" "$BUILD/scripts/postinst"
INSTALL_PREFIX="$MMX_INSTALL_PREFIX" \
  render "$ROOT/packaging/templates/prerm.tmpl" "$BUILD/scripts/prerm"
INSTALL_PREFIX="$MMX_INSTALL_PREFIX" \
  render "$ROOT/packaging/templates/postrm.tmpl" "$BUILD/scripts/postrm"
chmod +x "$BUILD/wrapper" "$BUILD/scripts/postinst" "$BUILD/scripts/prerm" "$BUILD/scripts/postrm"

# ---- Package ----------------------------------------------------------------
DEB_NAME="${MMX_PKG_NAME}_${PRODUCT_VERSION}_${MMX_DEB_ARCH}.deb"
RPM_NAME="${MMX_PKG_NAME}-${PRODUCT_VERSION}.${MMX_RPM_ARCH}.rpm"

info "==> Building .deb"
( cd "$ROOT" && nfpm package --config build/nfpm.yaml --packager deb --target "$DIST/$DEB_NAME" )
info "==> Building .rpm"
( cd "$ROOT" && nfpm package --config build/nfpm.yaml --packager rpm --target "$DIST/$RPM_NAME" )

( cd "$DIST" && sha256sum "$DEB_NAME" "$RPM_NAME" > "checksums_${MMX_PKG_NAME}_${PRODUCT_VERSION}_${MMX_DEB_ARCH}.txt" )

info "==> Built:"
ls -lh "$DIST/$DEB_NAME" "$DIST/$RPM_NAME" "$DIST/checksums_${MMX_PKG_NAME}_${PRODUCT_VERSION}_${MMX_DEB_ARCH}.txt"
