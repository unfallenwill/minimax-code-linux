#!/usr/bin/env bash
# Compatibility entry point for the native-addon stage. The implementation
# was split into three modules; source them all so callers (install.sh, tests)
# can keep using `. scripts/lib_native.sh` and the original function API:
#
#   scripts/lib_native_strip.sh   strip darwin-only packages + stub mac-permissions
#   scripts/lib_native_pkgs.sh    install linux platform packages from npm
#   scripts/lib_native_build.sh   better-sqlite3 / node-pty / opencode / session-transfer-client
#
# Ordering matters: pkgs and build both rely on helpers defined in strip.sh.
# shellcheck shell=bash
NATIVE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$NATIVE_LIB_DIR/lib_native_strip.sh"
# shellcheck disable=SC1091
. "$NATIVE_LIB_DIR/lib_native_pkgs.sh"
# shellcheck disable=SC1091
. "$NATIVE_LIB_DIR/lib_native_build.sh"
