#!/usr/bin/env bash
# Shared constants, logging, and helpers for the MiniMax Code Linux build.
# Sourced by install.sh and the scripts/lib_*.sh files. Do not execute directly.
# shellcheck shell=bash

set -o pipefail

# ---- Edition (region) ----
# MiniMax ships TWO separate editions of the desktop app. They are different
# applications in every way that matters to the user: different backend and
# login hosts, different bundle id, different UI language.
#
#   cn        agent.minimax.cn   bundle id com.minimax.agent.cn   locale zh
#   overseas  agent.minimax.io   bundle id com.minimax.agent      locale en
#
# The payload is per-edition (app.asar carries a different .env.local), so the
# edition has to be chosen BEFORE the upstream artifact is fetched. MMX_REGION
# selects it; every identity value below can still be overridden individually.
: "${MMX_REGION:=cn}"
case "$MMX_REGION" in
  cn)
    MMX_REGION_APP_ID=com.minimax.agent.cn
    MMX_REGION_PKG_NAME=minimax-code
    MMX_REGION_DISPLAY="MiniMax Code"
    MMX_REGION_DOMAIN=https://agent.minimax.cn
    MMX_REGION_SCHEME=minimax-cn
    MMX_REGION_MANIFEST=https://filecdn.minimax.chat/public/minimax-agent-prod/release
    ;;
  overseas)
    MMX_REGION_APP_ID=com.minimax.agent
    MMX_REGION_PKG_NAME=minimax-code-global
    MMX_REGION_DISPLAY="MiniMax Code (Global)"
    MMX_REGION_DOMAIN=https://agent.minimax.io
    MMX_REGION_SCHEME=minimax
    MMX_REGION_MANIFEST=https://file.cdn.minimax.io/public/minimax-agent-prod/release
    ;;
  *)
    printf '[error] Unknown MMX_REGION=%s (expected: cn | overseas)\n' "$MMX_REGION" >&2
    exit 1
    ;;
esac

# ---- Identity (overridable via env) ----
# Each edition gets its own package name, install prefix, desktop entry and
# icon, so the two can be installed side by side and can never fight over the
# same dpkg/rpm file list.
: "${MMX_APP_ID:=$MMX_REGION_APP_ID}"
: "${MMX_PKG_NAME:=$MMX_REGION_PKG_NAME}"
: "${MMX_DISPLAY:=$MMX_REGION_DISPLAY}"
: "${MMX_WMCLASS:=$MMX_PKG_NAME}"
: "${MMX_BIN:=$MMX_PKG_NAME}"
: "${MMX_INSTALL_PREFIX:=/opt/$MMX_PKG_NAME}"    # in-package path used by nfpm templates
: "${MMX_SCHEME:=$MMX_REGION_SCHEME}"            # deep-link scheme registered by the app
: "${MMX_RELEASE_TAG_PREFIX:=$MMX_REGION_PKG_NAME-v}"
: "${MMX_ELECTRON_FALLBACK:=38.3.0}"
: "${MMX_ELECTRON_REPO:=electron/electron}"       # GitHub owner/repo for Electron releases
: "${MMX_UPSTREAM_DMG_URL:=}"                     # set for CI auto-download; empty => require --dmg
: "${MMX_CACHE_DIR:=$HOME/.cache/minimax-code-linux}"

# ---- Logging ----
_log() { printf '%s\n' "$*" >&2; }
info() { _log "[info] $*"; }
warn() { _log "[warn] $*"; }
die()  { _log "[error] $*"; exit 1; }

# ---- Destructive-path guards ----------------------------------------------
# install.sh (and other stages) `rm -rf` their output directories, so output
# paths must never be allowed to resolve to something catastrophic. Refuse,
# with a clear error: empty paths, existing non-directories, "/", common
# system directories, $HOME itself, the repository root, and any ancestor of
# the repository or of $HOME (e.g. "--install-dir /home" when the repo lives
# under /home). Building INSIDE the repo (the default build/minimax-code) or
# anywhere else below all of these is fine.
assert_safe_output_dir() {
  local dir="$1" what="${2:-output dir}"
  [ -n "$dir" ] || die "$what: empty path"
  local canon
  canon="$(readlink -m "$dir")" || die "$what: cannot canonicalize '$dir'"
  if [ -e "$canon" ] && [ ! -d "$canon" ]; then
    die "$what: not a directory: $canon"
  fi
  if [ "$canon" = "/" ]; then
    die "$what: refusing unsafe path '/'"
  fi
  case "$canon" in
    /bin|/boot|/dev|/etc|/home|/lib|/lib32|/lib64|/libx32|/media|/mnt|/opt|\
/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/usr/local|/var)
      die "$what: refusing unsafe system path '$canon'" ;;
  esac
  local repo="${MMX_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local task_home_dir="${HOME:-}"
  if [ "$repo" = "$canon" ] || [ "${repo#"$canon"/}" != "$repo" ]; then
    die "$what: refusing unsafe path '$canon' (would delete the repository at $repo)"
  fi
  if [ -n "$task_home_dir" ]; then
    if [ "$task_home_dir" = "$canon" ] || [ "${task_home_dir#"$canon"/}" != "$task_home_dir" ]; then
      die "$what: refusing unsafe path '$canon' (would delete the home directory $task_home_dir)"
    fi
  fi
  # Inside the repository only the gitignored build/ tree may be replaced;
  # anything else (scripts/, packaging/, tracked files, ...) would be rm -rf'd
  # away by the publisher.
  if [ "${canon#"$repo"/}" != "$canon" ]; then
    case "$canon" in
      "$repo"/build/*) ;;
      *) die "$what: refusing path inside the repository ($canon); use a path under $repo/build/ or outside the repo" ;;
    esac
  fi
}

# Publish a fully-built staging directory as the final output directory:
#   publish_staged_dir <staging-dir> <final-dir>
# Both must be on the same filesystem (staging is typically a mktemp sibling of
# final, so publishing is a rename). The previous <final-dir>, if any, is moved
# aside first and only deleted AFTER the staged tree is in place; if any move
# fails, the old tree is restored best-effort. NOTE: this is a sequence of two
# renames, not an atomic exchange — there is a brief window where <final-dir>
# does not exist, and a concurrent publisher can still race. `mv -T` keeps each
# rename from nesting into an existing destination. On success <staging-dir> no
# longer exists (it was renamed).
publish_staged_dir() {
  local staging="$1" final="$2"
  if [ ! -d "$staging" ]; then
    warn "publish: staging directory missing: $staging"
    return 1
  fi
  local parent old
  parent="$(dirname "$final")"
  old="$(mktemp -d "$parent/.mmx-publish-old.XXXXXX")" && rmdir "$old" \
    || { warn "publish: cannot reserve backup name in $parent"; return 1; }
  if [ -e "$final" ]; then
    mv -T "$final" "$old" || { warn "publish: cannot move old $final aside"; return 1; }
  fi
  if mv -T "$staging" "$final"; then
    [ -e "$old" ] && rm -rf "$old"
    return 0
  fi
  if [ -e "$old" ]; then
    if mv -T "$old" "$final"; then
      warn "publish: could not move staged build into $final; previous contents left intact"
    else
      warn "publish: could not move staged build into $final AND could not restore the old tree; it is preserved at $old"
    fi
  fi
  return 1
}

# ---- Downloads --------------------------------------------------------------
# Download <url> to the cache path <dest> without ever leaving a partial file
# at <dest>: curl writes to a unique mktemp file next to <dest> and the temp
# file is renamed onto <dest> only after the download is complete and (when an
# optional verifier is given) validated:
#   fetch_to_cache <url> <dest> [verify-cmd ...]
# The verifier is invoked with the temp file path and must return 0 for the
# download to be published; a verification failure keeps any previous cache
# entry. All cleanup is done inside a subshell with a local EXIT/INT/TERM trap,
# so the caller's traps are untouched and interrupted downloads leave no temp
# file behind. Returns non-zero on failure; callers decide whether to die or
# degrade gracefully.
fetch_to_cache() (
  local url="$1" dest="$2"; shift 2
  local dir
  dir="$(dirname "$dest")"
  mkdir -p "$dir" || return 1
  local tmp
  tmp="$(mktemp "$dir/.fetch-to-cache.XXXXXXXX")" || return 1
  cleanup() { rm -f "$tmp"; }
  trap cleanup EXIT INT TERM
  info "Downloading $url ..."
  if ! curl -fL --retry 3 --connect-timeout 30 -o "$tmp" "$url"; then
    warn "Download failed: $url"
    return 1
  fi
  if [ ! -s "$tmp" ]; then
    warn "Download produced an empty file: $url"
    return 1
  fi
  if [ "$#" -gt 0 ]; then
    if ! "$@" "$tmp"; then
      warn "Downloaded file failed validation, keeping existing cache entry: $dest"
      return 1
    fi
  fi
  if ! mv -f "$tmp" "$dest"; then
    return 1
  fi
  return 0
)

# ---- Helpers ----
# Fail if any of the listed commands is missing.
require_cmd() {
  local missing=() c
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  [ "${#missing[@]}" -eq 0 ] || die "Missing required commands: ${missing[*]}"
}

# Map a friendly arch token to npm/electron/deb/rpm arch strings.
# $1 = x64 ; exports MMX_ELECTRON_ARCH MMX_NPM_ARCH MMX_DEB_ARCH MMX_RPM_ARCH
resolve_arch() {
  case "$1" in
    x64|amd64)
      MMX_ELECTRON_ARCH=x64 MMX_NPM_ARCH=x64 MMX_DEB_ARCH=amd64 MMX_RPM_ARCH=x86_64 ;;
    *)
      die "Unknown arch '$1' (only x64 is supported)" ;;
  esac
  export MMX_ELECTRON_ARCH MMX_NPM_ARCH MMX_DEB_ARCH MMX_RPM_ARCH
}
