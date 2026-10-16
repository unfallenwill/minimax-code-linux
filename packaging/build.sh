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
# Download goes through fetch_to_cache: the cached DMG is replaced only after
# a complete (optionally validated) download, so a failed download never
# corrupts it.
if [ -z "$DMG" ]; then
  [ -n "$DMG_URL" ] || die "Provide DMG=<path> or DMG_URL=<url>."
  DMG="$MMX_CACHE_DIR/minimax-code.dmg"
  fetch_to_cache "$DMG_URL" "$DMG" || die "DMG download failed"
fi
[ -f "$DMG" ] || die "DMG not found: $DMG"
# Only characters valid in deb/rpm versions; anything else would produce a
# package nfpm (or the target distro's package manager) rejects later.
if [ -n "$PRODUCT_VERSION" ] && ! printf '%s' "$PRODUCT_VERSION" | grep -qE '^[0-9A-Za-z.+:~-]+$'; then
  die "PRODUCT_VERSION contains characters invalid in package versions: '$PRODUCT_VERSION'"
fi

BUILD="$ROOT/build"
DIST="$ROOT/dist"
PAYLOAD="$BUILD/payload"
mkdir -p "$DIST" "$BUILD/scripts"

# ---- Build the runnable Linux app -------------------------------------------
# install.sh stages the build and publishes best-effort (the publish is two
# renames, not an atomic exchange): a failed app build normally leaves any
# previous payload tree intact, but the final batch mv of artifacts into
# dist/ is not atomic as a whole — a mid-move crash can leave dist/ partially
# updated.
info "==> Building app (arch=$ARCH) from $DMG"
"$ROOT/install.sh" --dmg "$DMG" --install-dir "$PAYLOAD"

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

# ---- Package (staged; published only if every artifact succeeds) ------------
DEB_NAME="${MMX_PKG_NAME}_${PRODUCT_VERSION}_${MMX_DEB_ARCH}.deb"
RPM_NAME="${MMX_PKG_NAME}-${PRODUCT_VERSION}.${MMX_RPM_ARCH}.rpm"
CHECKSUMS_NAME="checksums_${MMX_PKG_NAME}_${PRODUCT_VERSION}_${MMX_DEB_ARCH}.txt"

# nfpm renders straight into a staging dir under dist/; the artifacts are moved
# into place only after BOTH packages and the checksum file succeeded. A failed
# run leaves any previously published artifacts for this arch untouched.
PKG_STAGE="$(mktemp -d "$DIST/.pkg-staging.XXXXXX")" \
  || die "Cannot create staging directory in $DIST"
trap 'rm -rf "$PKG_STAGE"' EXIT

info "==> Building .deb"
( cd "$ROOT" && nfpm package --config build/nfpm.yaml --packager deb --target "$PKG_STAGE/$DEB_NAME" )
info "==> Building .rpm"
( cd "$ROOT" && nfpm package --config build/nfpm.yaml --packager rpm --target "$PKG_STAGE/$RPM_NAME" )

( cd "$PKG_STAGE" && sha256sum "$DEB_NAME" "$RPM_NAME" > "$CHECKSUMS_NAME" )

info "==> Publishing artifacts -> $DIST"
mv -f "$PKG_STAGE/$DEB_NAME" "$PKG_STAGE/$RPM_NAME" "$PKG_STAGE/$CHECKSUMS_NAME" "$DIST/"

info "==> Built:"
ls -lh "$DIST/$DEB_NAME" "$DIST/$RPM_NAME" "$DIST/$CHECKSUMS_NAME"
