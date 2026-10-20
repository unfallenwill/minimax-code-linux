#!/usr/bin/env bash
# Offline regression tests for the destructive boundaries of the MiniMax Code
# Linux build pipeline. No network, no DMG, no GUI: every external effect is
# produced by stub commands on PATH and fixture files under a mktemp sandbox,
# so the suite is safe to run anywhere (also useful in CI).
#
#   tests/run.sh
#
# Covered:
#   1. install.sh argument/output validation refuses dangerous --install-dir
#      values (/, system dirs, $HOME, the repo and its ancestors, non-
#      directories) and bad --dmg usage, BEFORE any work runs.
#   2. install.sh builds into a sibling staging dir and atomically replaces an
#      old installation only on success (end-to-end, fully stubbed pipeline).
#   3. A mid-build failure (stubbed unzip) leaves the old installation byte-
#      for-byte intact and removes the staging directory.
#   4. publish_staged_dir unit behaviour, including the restore path when the
#      final rename fails (stubbed mv), and the mv -T no-nesting guarantee when
#      the destination appears mid-publish.
#   5. fetch_to_cache never publishes partial/empty/unvalidated downloads and
#      preserves a previous cache entry on failure; interruption leaves no temp
#      file and does not pollute the caller's traps.
#   6. Electron cache validation: a corrupt cached archive is detected and re-
#      downloaded; a valid one is reused without any network call.
#   7. The split native modules (lib_native_strip.sh / _pkgs.sh / _build.sh)
#      expose exactly the former lib_native.sh API (also via the restored
#      compat entry scripts/lib_native.sh), and the strip/stub stage
#      keeps its behaviour on a synthetic node_modules tree.
#   8. The test run itself does not dirty the repository (git status snapshot).
#   9. Edition (region) handling: each edition builds with its own app id and
#      package identity, a payload from the other edition is refused, and an
#      unknown region is rejected.
set -u
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

for cmd in bash python3 node unzip mktemp; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "tests: missing command: $cmd" >&2; exit 2; }
done

PASS=0 FAIL=0
pass() { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$*"; }
fl()   { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$*"; }
run_case() { # run_case <name> <function...>
  local name="$1"; shift
  if "$@"; then pass "$name"; else fl "$name"; fi
}
expect_die() { # expect_die <name> <stderr-pattern> <cmd...>
  local name="$1" pattern="$2"; shift 2
  local out rc
  out="$("$@" 2>&1 1>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q "$pattern"; then
    pass "$name"
  else
    fl "$name"
    printf '%s\n' "$out" | sed 's/^/       /' >&2
  fi
}
assert_ok()  { [ "$1" -eq 0 ] && [ "$2" -eq 0 ]; }   # helper for command -v style checks

SBOX="$(mktemp -d /tmp/minimax-code-tests.XXXXXX)"
trap 'rm -rf "$SBOX"' EXIT

# Snapshot for Group 8: the test run itself must not dirty the repository.
REPO_STATUS_BEFORE="$(git -C "$ROOT" status --porcelain 2>/dev/null || true)"
case_repo_untouched() {
  local now
  now="$(git -C "$ROOT" status --porcelain 2>/dev/null || true)"
  [ "$now" = "$REPO_STATUS_BEFORE" ]
}

REAL_MV="$(command -v mv)"
REAL_UNZIP="$(command -v unzip)"

# ---- Sandbox assembly --------------------------------------------------------
mkdir -p "$SBOX/stub-bin" "$SBOX/stub-unzip" "$SBOX/stub-mv" "$SBOX/out"
cp "$ROOT/tests/stubs/curl" "$SBOX/stub-bin/curl"
cp "$ROOT/tests/stubs/7z" "$SBOX/stub-bin/7z"
cp "$ROOT/tests/stubs/unzip-fail" "$SBOX/stub-unzip/unzip"
cp "$ROOT/tests/stubs/mv-block-first" "$SBOX/stub-mv/mv"
chmod +x "$SBOX/stub-bin/"* "$SBOX/stub-unzip/unzip" "$SBOX/stub-mv/mv"

ELECTRON_ZIP="$SBOX/electron-fixture.zip"
python3 "$ROOT/tests/fixtures/make_electron_zip.py" "$ELECTRON_ZIP" >/dev/null

: > "$SBOX/curl-pipeline.log"
: > "$SBOX/curl-units.log"

# A fake repository root for install.sh's ROOT-dependent lookups: the REAL
# asar extractor script plus a fake @electron/asar module (no npm/network).
FAKEROOT="$SBOX/fakeroot"
mkdir -p "$FAKEROOT/scripts" "$FAKEROOT/build/asar-tools/node_modules/@electron/asar"
cp "$ROOT/scripts/asar_extract.js" "$FAKEROOT/scripts/asar_extract.js"
cp "$ROOT/tests/fixtures/fake_asar/package.json" \
   "$FAKEROOT/build/asar-tools/node_modules/@electron/asar/package.json"
cp "$ROOT/tests/fixtures/fake_asar/index.js" \
   "$FAKEROOT/build/asar-tools/node_modules/@electron/asar/index.js"

printf 'stub-dmg\n' > "$SBOX/fake.dmg"

# ============================================================================
# Group 1: argument / output-directory validation (before any work runs)
# ============================================================================
t_val() { bash "$ROOT/install.sh" "$@"; }
expect_die "1a rejects --install-dir /" \
  "refusing unsafe path '/'" t_val --dmg "$SBOX/fake.dmg" --install-dir /
expect_die "1b rejects --install-dir \$HOME" \
  "refusing unsafe path" t_val --dmg "$SBOX/fake.dmg" --install-dir "${HOME:-/root}"
expect_die "1c rejects --install-dir <repo root>" \
  "would delete the repository" t_val --dmg "$SBOX/fake.dmg" --install-dir "$ROOT"
expect_die "1d rejects an ancestor of the repo" \
  "would delete the repository" t_val --dmg "$SBOX/fake.dmg" --install-dir "$(dirname "$ROOT")"
expect_die "1e rejects system dir /usr" \
  "refusing unsafe system path '/usr'" t_val --dmg "$SBOX/fake.dmg" --install-dir /usr
printf 'not a dir\n' > "$SBOX/plain-file"
expect_die "1f rejects an existing non-directory" \
  "not a directory" t_val --dmg "$SBOX/fake.dmg" --install-dir "$SBOX/plain-file"
expect_die "1f2 rejects tracked repo dirs (scripts/)" \
  "inside the repository" t_val --dmg "$SBOX/fake.dmg" --install-dir "$ROOT/scripts"
expect_die "1f3 rejects the repo build dir itself" \
  "inside the repository" t_val --dmg "$SBOX/fake.dmg" --install-dir "$ROOT/build"
expect_die "1g rejects missing --dmg value" \
  "requires a path argument" t_val --dmg
expect_die "1h rejects missing --install-dir value" \
  "requires a directory argument" t_val --install-dir
expect_die "1i rejects unknown argument" \
  "Unknown argument" t_val --bogus x
expect_die "1j rejects nonexistent --dmg file" \
  "file not found" t_val --dmg "$SBOX/nope.dmg" --install-dir "$SBOX/out/app-validate"
[ ! -e "$SBOX/out/app-validate" ] && pass "1k nothing created for rejected runs" \
  || fl "1k nothing created for rejected runs"
[ -d / ] && [ -d "$ROOT/scripts" ] && pass "1l critical paths untouched" \
  || fl "1l critical paths untouched"

# ============================================================================
# Group 2: full pipeline (stubbed 7z/curl/asar) — staging + atomic publish
# ============================================================================
case_pipeline_success() {
  mkdir -p "$SBOX/out/app"
  echo "previous install" > "$SBOX/out/app/old-install.marker"
  # shellcheck disable=SC2016
  if env \
      PATH="$SBOX/stub-bin:$PATH" \
      ROOT="$FAKEROOT" \
      MMX_CACHE_DIR="$SBOX/cache" \
      MMX_TEST_CURL_LOG="$SBOX/curl-pipeline.log" \
      MMX_TEST_SERVE_FILE="$ELECTRON_ZIP" \
      bash "$ROOT/install.sh" --dmg "$SBOX/fake.dmg" --install-dir "$SBOX/out/app" \
      >"$SBOX/install-success.log" 2>&1; then
    :
  else
    echo "install.sh exited non-zero; log:" >&2
    tail -30 "$SBOX/install-success.log" >&2
    return 1
  fi
  local app="$SBOX/out/app"
  [ -x "$app/start.sh" ]            || { echo "start.sh missing/not exec" >&2; return 1; }
  [ -x "$app/electron" ]            || { echo "electron missing/not exec" >&2; return 1; }
  [ -f "$app/build-info.json" ]     || { echo "build-info.json missing" >&2; return 1; }
  grep -q '"upstream_version": "9.9.9"' "$app/build-info.json" \
                                    || { echo "wrong upstream version" >&2; return 1; }
  grep -q '"electron_version": "38.3.0"' "$app/build-info.json" \
                                    || { echo "wrong electron version" >&2; return 1; }
  grep -q '"minimax-code"' "$app/resources/app/package.json" \
                                    || { echo "patch_linux did not rewrite package name" >&2; return 1; }
  grep -q 'isPackaged' "$app/resources/app/dist/main/index.js" \
                                    || { echo "patch_linux did not patch main entry" >&2; return 1; }
  [ -f "$app/resources/resources/pptx-core/runtime.json" ] \
                                    || { echo "runtime resources not staged" >&2; return 1; }
  [ ! -e "$app/old-install.marker" ] || { echo "old install not replaced" >&2; return 1; }
  # no staging / backup leftovers in the output parent
  if find "$SBOX/out" -maxdepth 1 \( -name '.minimax-code-staging.*' -o -name '.mmx-publish-old.*' \) \
      | grep -q .; then
    echo "staging leftovers in $(dirname "$app")" >&2; return 1
  fi
  # exactly one download happened (the electron zip), and the cache entry is a
  # valid zip
  [ "$(wc -l < "$SBOX/curl-pipeline.log")" -eq 1 ] \
                                    || { echo "unexpected curl call count" >&2; return 1; }
  unzip -tqq "$SBOX/cache/electron/electron-v38.3.0-linux-x64.zip" >/dev/null 2>&1 \
                                    || { echo "cached electron zip invalid" >&2; return 1; }
  return 0
}
run_case "2  pipeline publishes staged build, replacing old install" case_pipeline_success

# ============================================================================
# Group 3: mid-build failure keeps the old installation intact
# ============================================================================
case_pipeline_failure_preserves_old() {
  local app="$SBOX/out/app"
  echo "sentinel-B" > "$app/sentinel-B"
  local before
  before="$(cd "$app" && find . -type f | sort | xargs sha256sum | sha256sum)"
  # shellcheck disable=SC2016
  if env \
      PATH="$SBOX/stub-unzip:$SBOX/stub-bin:$PATH" \
      MMX_TEST_REAL_UNZIP="$REAL_UNZIP" \
      ROOT="$FAKEROOT" \
      MMX_CACHE_DIR="$SBOX/cache" \
      MMX_TEST_CURL_LOG="$SBOX/curl-pipeline.log" \
      MMX_TEST_SERVE_FILE="$ELECTRON_ZIP" \
      bash "$ROOT/install.sh" --dmg "$SBOX/fake.dmg" --install-dir "$SBOX/out/app" \
      >"$SBOX/install-failure.log" 2>&1; then
    echo "expected the stubbed-unzip run to fail" >&2
    return 1
  fi
  grep -q "Electron unzip failed" "$SBOX/install-failure.log" \
    || { echo "failed for the wrong reason; log:" >&2; tail -30 "$SBOX/install-failure.log" >&2; return 1; }
  local after
  after="$(cd "$app" && find . -type f | sort | xargs sha256sum | sha256sum)"
  [ "$before" = "$after" ] || { echo "old install changed by failed run" >&2; return 1; }
  [ -f "$app/sentinel-B" ] || { echo "sentinel lost" >&2; return 1; }
  if find "$SBOX/out" -maxdepth 1 \( -name '.minimax-code-staging.*' -o -name '.mmx-publish-old.*' \) \
      | grep -q .; then
    echo "failed run left staging leftovers" >&2; return 1
  fi
  return 0
}
run_case "3  failed build leaves old install byte-identical, cleans staging" \
  case_pipeline_failure_preserves_old

# ============================================================================
# Group 4: publish_staged_dir unit behaviour
# ============================================================================
case_pub_replace() {
  (
    set -u
    . "$ROOT/scripts/lib_common.sh"
    local d="$SBOX/pub1"
    rm -rf "$d"; mkdir -p "$d/final" "$d/stage"
    echo old > "$d/final/marker"; echo new > "$d/stage/new"
    publish_staged_dir "$d/stage" "$d/final" || exit 1
    [ "$(cat "$d/final/new")" = new ] || exit 1
    [ ! -e "$d/final/marker" ] || exit 1
    [ ! -e "$d/stage" ] || exit 1
    ! ls -A "$d" | grep -q 'mmx-publish-old' || exit 1
    exit 0
  )
}
case_pub_fresh() {
  (
    set -u
    . "$ROOT/scripts/lib_common.sh"
    local d="$SBOX/pub2"
    rm -rf "$d"; mkdir -p "$d/stage"
    echo new > "$d/stage/new"
    publish_staged_dir "$d/stage" "$d/final" || exit 1
    [ "$(cat "$d/final/new")" = new ] || exit 1
    exit 0
  )
}
case_pub_missing_staging() {
  (
    set -u
    . "$ROOT/scripts/lib_common.sh"
    local d="$SBOX/pub3"
    rm -rf "$d"; mkdir -p "$d/final"
    echo old > "$d/final/marker"
    publish_staged_dir "$d/absent" "$d/final" && exit 1
    [ "$(cat "$d/final/marker")" = old ] || exit 1
    exit 0
  )
}
case_pub_restore_on_mv_failure() {
  (
    set -u
    . "$ROOT/scripts/lib_common.sh"
    local d="$SBOX/pub4"
    rm -rf "$d"; mkdir -p "$d/final" "$d/stage"
    echo old > "$d/final/marker"; echo new > "$d/stage/new"
    export MMX_TEST_BLOCK_MV_SRC="$d/stage"
    export MMX_TEST_REAL_MV="$REAL_MV"
    PATH="$SBOX/stub-mv:$PATH" publish_staged_dir "$d/stage" "$d/final" && exit 1
    [ "$(cat "$d/final/marker")" = old ] || exit 1   # old tree restored
    [ -e "$d/stage" ] || exit 1                       # staging left for caller cleanup
    ! ls -A "$d" | grep -q 'mmx-publish-old' || exit 1
    exit 0
  )
}
# Regression: if <final-dir> appears between the backup rename and the publish
# rename (concurrent publisher), plain mv would nest the staging tree inside
# the existing destination (final/stage/...). mv -T must make the publish fail
# instead of nesting, and the old tree must stay intact in its backup slot.
case_pub_no_nesting_when_dest_appears() {
  (
    set -u
    . "$ROOT/scripts/lib_common.sh"
    local d="$SBOX/pub5"
    rm -rf "$d"; mkdir -p "$d/final" "$d/stage"
    echo old > "$d/final/marker"; echo new > "$d/stage/new"
    # Stub mv: the backup move (final -> old) passes through and then a
    # concurrent publisher re-creates the destination; the publish move
    # (stage -> final) also passes through, so without mv -T it would nest
    # staging inside the existing destination.
    mkdir -p "$SBOX/stub-race-mv"
    cat > "$SBOX/stub-race-mv/mv" <<STUB
#!/bin/sh
if [ "\$1" = -T ] && [ "\$3" = "$d/stage" ]; then
  exec "$REAL_MV" "\$@"
fi
if [ "\$1" = -T ] && [ "\$2" = "$d/final" ]; then
  "$REAL_MV" "\$@" || exit \$?
  if [ ! -e "$d/.raced" ]; then
    touch "$d/.raced"   # only the first move is raced by the publisher
    mkdir "$d/final"
    echo concurrent > "$d/final/racer"   # non-empty: rename cannot replace it
  fi
  exit 0
fi
exec "$REAL_MV" "\$@"
STUB
    chmod +x "$SBOX/stub-race-mv/mv"
    PATH="$SBOX/stub-race-mv:$PATH" publish_staged_dir "$d/stage" "$d/final" && exit 1
    # The racer's tree must be intact, not clobbered, and our staging tree
    # must NOT have been nested inside it (that is what plain mv would do).
    [ "$(cat "$d/final/racer")" = concurrent ] || exit 1
    [ ! -e "$d/final/stage" ] || exit 1
    [ -e "$d/stage" ] || exit 1                       # staging left for caller cleanup
    # The old tree was not destroyed: it lives in the backup dir whose real
    # path publish_staged_dir reports in its warning.
    local backup
    backup="$(ls -d "$d"/.mmx-publish-old.* 2>/dev/null | head -1)"
    [ -n "$backup" ] || exit 1
    [ "$(cat "$backup/marker")" = old ] || exit 1
    exit 0
  )
}
run_case "4a publish replaces existing dir, consumes staging"      case_pub_replace
run_case "4b publish creates missing dir"                          case_pub_fresh
run_case "4c publish fails cleanly when staging is missing"        case_pub_missing_staging
run_case "4d publish restores old dir when final rename fails"     case_pub_restore_on_mv_failure
run_case "4e publish refuses to nest when dest appears mid-publish" case_pub_no_nesting_when_dest_appears

# ============================================================================
# Group 5: fetch_to_cache — partial/empty downloads never pollute the cache
# ============================================================================
case_fetch_units() {
  (
    set -u
    . "$ROOT/scripts/lib_common.sh"
    local d="$SBOX/fetch"
    rm -rf "$d"; mkdir -p "$d"
    export PATH="$SBOX/stub-bin:$PATH"
    export MMX_TEST_CURL_LOG="$SBOX/curl-units.log"
    unset MMX_TEST_SERVE_FILE

    fetch_to_cache "https://unit.test/ok" "$d/dest1" || exit 1
    [ "$(cat "$d/dest1")" = "payload-of https://unit.test/ok" ] || exit 1

    fetch_to_cache "https://unit.test/fail" "$d/dest2" && exit 1
    [ ! -e "$d/dest2" ] || exit 1

    echo keepme > "$d/dest3"
    fetch_to_cache "https://unit.test/fail" "$d/dest3" && exit 1
    [ "$(cat "$d/dest3")" = keepme ] || exit 1

    fetch_to_cache "https://unit.test/empty" "$d/dest4" && exit 1
    [ ! -e "$d/dest4" ] || exit 1

    # Verifier hook: a download that fails validation must not replace the
    # previous cache entry.
    echo keepme > "$d/dest5"
    fetch_to_cache "https://unit.test/ok" "$d/dest5" false && exit 1
    [ "$(cat "$d/dest5")" = keepme ] || exit 1
    fetch_to_cache "https://unit.test/ok" "$d/dest5" test -s || exit 1
    [ "$(cat "$d/dest5")" = "payload-of https://unit.test/ok" ] || exit 1

    # The caller's traps must be untouched and no temp file may survive.
    caller_trap_ran=0
    trap 'caller_trap_ran=1; trap - EXIT INT TERM' EXIT INT TERM
    fetch_to_cache "https://unit.test/fail" "$d/dest6" && : # ignore rc
    rc=$?
    trap - EXIT INT TERM
    [ "$caller_trap_ran" -eq 0 ] || { echo "fetch_to_cache polluted caller traps" >&2; exit 1; }
    [ "$rc" -ne 0 ] || exit 1

    ! ls -A "$d" | grep -qE '\.(tmp\.|fetch-to-cache\.)' || exit 1   # no temp-file leftovers
    exit 0
  )
}
run_case "5  fetch_to_cache: validated atomic publish, old entry preserved on failure, no trap pollution" case_fetch_units

# ============================================================================
# Group 6: Electron cache validation
# ============================================================================
case_electron_cache() {
  (
    set -u
    . "$ROOT/scripts/lib_common.sh"
    . "$ROOT/scripts/lib_electron.sh"
    local d="$SBOX/electron-cache"
    rm -rf "$d"; mkdir -p "$d/cache/electron"
    export PATH="$SBOX/stub-bin:$PATH"           # stub curl; REAL unzip
    export MMX_TEST_CURL_LOG="$d/curl.log"
    export MMX_TEST_SERVE_FILE="$ELECTRON_ZIP"
    export MMX_CACHE_DIR="$d/cache"

    : > "$d/curl.log"
    echo garbage > "$d/cache/electron/electron-v9.9.9-linux-x64.zip"
    electron_install 9.9.9 x64 "$d/dest1" || exit 1
    [ -x "$d/dest1/electron" ] || exit 1
    unzip -tqq "$d/cache/electron/electron-v9.9.9-linux-x64.zip" >/dev/null 2>&1 || exit 1
    [ "$(wc -l < "$d/curl.log")" -eq 1 ] || exit 1   # corrupt cache was re-fetched

    : > "$d/curl.log"
    rm -rf "$d/dest2"
    electron_install 9.9.9 x64 "$d/dest2" || exit 1
    [ -x "$d/dest2/electron" ] || exit 1
    [ ! -s "$d/curl.log" ] || exit 1                 # valid cache: no download at all
    exit 0
  )
}
run_case "6  electron cache: corrupt archive re-downloaded, valid reused offline" \
  case_electron_cache

# ============================================================================
# Group 7: split native modules — API surface + strip/stub behaviour
# ============================================================================
case_native_modules() {
  (
    set -u
    . "$ROOT/scripts/lib_common.sh"
    . "$ROOT/scripts/lib_native_strip.sh"
    . "$ROOT/scripts/lib_native_pkgs.sh"
    . "$ROOT/scripts/lib_native_build.sh"
    local fn
    for fn in native_strip_macos native_stub_mac_permissions \
              native_swap_screenshots native_install_mariozechner_clipboard \
              native_install_vscode_ripgrep native_install_cua_driver \
              native_install_opencode native_install_better_sqlite3 \
              native_install_node_pty_linux native_build_session_transfer_client; do
      [ "$(type -t "$fn")" = function ] || { echo "missing function: $fn" >&2; exit 1; }
    done
    local nm="$SBOX/nm"
    rm -rf "$nm"
    mkdir -p "$nm/node-screenshots-darwin-x64" \
             "$nm/node-screenshots-win32-x64-msvc" \
             "$nm/@mariozechner/clipboard-darwin-arm64" \
             "$nm/@vscode/ripgrep-darwin-x64" \
             "$nm/@nut-tree/libnut-darwin" \
             "$nm/@nut-tree/libnut-linux" \
             "$nm/@nut-tree/node-mac-permissions" \
             "$nm/node-pty/prebuilds/darwin-x64" \
             "$nm/node-pty/prebuilds/linux-x64"
    echo x > "$nm/node-pty/prebuilds/linux-x64/pty.node"
    echo x > "$nm/node-pty/prebuilds/darwin-x64/pty.node"

    native_strip_macos "$nm" || exit 1
    native_stub_mac_permissions "$nm" || exit 1

    [ ! -e "$nm/node-screenshots-darwin-x64" ] || exit 1
    [ ! -e "$nm/node-screenshots-win32-x64-msvc" ] || exit 1
    [ ! -e "$nm/@mariozechner/clipboard-darwin-arm64" ] || exit 1
    [ ! -e "$nm/@vscode/ripgrep-darwin-x64" ] || exit 1
    [ ! -e "$nm/@nut-tree/libnut-darwin" ] || exit 1
    [ ! -e "$nm/node-pty/prebuilds/darwin-x64" ] || exit 1
    [ -f "$nm/node-pty/prebuilds/linux-x64/pty.node" ] || exit 1   # linux kept
    [ -d "$nm/@nut-tree/libnut-linux" ] || exit 1                  # N-API prebuild kept
    node -e '
      const m = require(process.argv[1]);
      if (typeof m.anything !== "function") process.exit(1);
      if (m.call() !== 0) process.exit(1);
    ' "$nm/@nut-tree/node-mac-permissions" || { echo "mac-permissions shim broken" >&2; exit 1; }
    exit 0
  )
}
case_native_compat_entry() {
  (
    set -u
    . "$ROOT/scripts/lib_common.sh"
    . "$ROOT/scripts/lib_native.sh"   # legacy entry must keep working
    local fn
    for fn in native_strip_macos native_stub_mac_permissions \
              native_install_opencode native_install_node_pty_linux; do
      [ "$(type -t "$fn")" = function ] || { echo "legacy lib_native.sh missing: $fn" >&2; exit 1; }
    done
    exit 0
  )
}
run_case "7a native modules expose the former lib_native.sh API + strip/stub" \
  case_native_modules
[ -f "$ROOT/scripts/lib_native.sh" ] \
  && run_case "7b legacy scripts/lib_native.sh restored as compat entry" case_native_compat_entry \
  || fl "7b legacy scripts/lib_native.sh restored as compat entry"

# ============================================================================
# Group 8: the test run did not dirty the repository
# ============================================================================
run_case "8  test run left the repository status unchanged" case_repo_untouched

# ============================================================================
# Group 9: edition (region) handling
#
# MiniMax ships two separate editions with different payloads. The build must
# (a) package the edition that was asked for, (b) refuse to package a payload
# from the other edition, and (c) record the edition in build-info.json.
# ============================================================================
case_edition_cn() {
  local app="$SBOX/out/app-cn"
  rm -rf "$app"
  # shellcheck disable=SC2016
  env \
    PATH="$SBOX/stub-bin:$PATH" \
    ROOT="$FAKEROOT" \
    MMX_CACHE_DIR="$SBOX/cache" \
    MMX_TEST_CURL_LOG="$SBOX/curl-pipeline.log" \
    MMX_TEST_SERVE_FILE="$ELECTRON_ZIP" \
    MMX_REGION=cn \
    MMX_TEST_ENV_LOCAL='NEXT_PUBLIC_DOMAIN_URL="https://agent.minimax.cn"
' \
    bash "$ROOT/install.sh" --dmg "$SBOX/fake.dmg" --install-dir "$app" \
    >"$SBOX/install-cn.log" 2>&1 || {
      echo "install.sh (cn) exited non-zero; log:" >&2; tail -20 "$SBOX/install-cn.log" >&2; return 1; }
  grep -q '"region": "cn"' "$app/build-info.json" \
    || { echo "build-info.json does not record region cn" >&2; return 1; }
  grep -q '"app_id": "com.minimax.agent.cn"' "$app/build-info.json" \
    || { echo "build-info.json does not record the CN app id" >&2; return 1; }
  grep -q '"minimax-code"' "$app/resources/app/package.json" \
    || { echo "package name not rewritten to the CN package id" >&2; return 1; }
  return 0
}
run_case "9a CN edition: builds, and records region/app_id/package name" case_edition_cn

case_edition_overseas() {
  local app="$SBOX/out/app-global"
  rm -rf "$app"
  # shellcheck disable=SC2016
  env \
    PATH="$SBOX/stub-bin:$PATH" \
    ROOT="$FAKEROOT" \
    MMX_CACHE_DIR="$SBOX/cache" \
    MMX_TEST_CURL_LOG="$SBOX/curl-pipeline.log" \
    MMX_TEST_SERVE_FILE="$ELECTRON_ZIP" \
    MMX_REGION=overseas \
    MMX_TEST_ENV_LOCAL='NEXT_PUBLIC_DOMAIN_URL="https://agent.minimax.io"
' \
    bash "$ROOT/install.sh" --dmg "$SBOX/fake.dmg" --install-dir "$app" \
    >"$SBOX/install-global.log" 2>&1 || {
      echo "install.sh (overseas) exited non-zero; log:" >&2; tail -20 "$SBOX/install-global.log" >&2; return 1; }
  grep -q '"region": "overseas"' "$app/build-info.json" \
    || { echo "build-info.json does not record region overseas" >&2; return 1; }
  grep -q '"app_id": "com.minimax.agent"' "$app/build-info.json" \
    || { echo "build-info.json does not record the global app id" >&2; return 1; }
  grep -q '"name": "minimax-code-global"' "$app/resources/app/package.json" \
    || { echo "package name not rewritten to the global package id" >&2; return 1; }
  return 0
}
run_case "9b global edition: builds, and records region/app_id/package name" case_edition_overseas

case_edition_mismatch() {
  local app="$SBOX/out/app-mismatch"
  rm -rf "$app"
  # A global payload downloaded while packaging the CN edition: the build must
  # refuse it instead of shipping a package that talks to the wrong backend.
  # shellcheck disable=SC2016
  if env \
    PATH="$SBOX/stub-bin:$PATH" \
    ROOT="$FAKEROOT" \
    MMX_CACHE_DIR="$SBOX/cache" \
    MMX_TEST_CURL_LOG="$SBOX/curl-pipeline.log" \
    MMX_TEST_SERVE_FILE="$ELECTRON_ZIP" \
    MMX_REGION=cn \
    MMX_TEST_ENV_LOCAL='NEXT_PUBLIC_DOMAIN_URL="https://agent.minimax.io"
' \
    bash "$ROOT/install.sh" --dmg "$SBOX/fake.dmg" --install-dir "$app" \
    >"$SBOX/install-mismatch.log" 2>&1; then
    echo "install.sh accepted a payload from the other edition" >&2
    return 1
  fi
  grep -q "Edition mismatch" "$SBOX/install-mismatch.log" \
    || { echo "failure did not name the edition mismatch" >&2; tail -20 "$SBOX/install-mismatch.log" >&2; return 1; }
  [ ! -e "$app" ] || { echo "a failed edition check still published an install dir" >&2; return 1; }
  return 0
}
run_case "9c edition guard refuses a payload from the other edition" case_edition_mismatch

case_region_profiles() {
  # Each profile is checked in its own subshell: lib_common.sh applies the
  # region defaults once per process, so a single shell cannot hold two.
  local r
  for r in cn overseas; do
    (
      set -u
      MMX_REGION="$r"
      . "$ROOT/scripts/lib_common.sh"
      case "$r" in
        cn)
          [ "$MMX_APP_ID" = "com.minimax.agent.cn" ] || { echo "cn app id wrong: $MMX_APP_ID" >&2; exit 1; }
          [ "$MMX_PKG_NAME" = "minimax-code" ]         || { echo "cn pkg name wrong: $MMX_PKG_NAME" >&2; exit 1; }
          [ "$MMX_INSTALL_PREFIX" = "/opt/minimax-code" ] || { echo "cn prefix wrong" >&2; exit 1; }
          [ "$MMX_RELEASE_TAG_PREFIX" = "minimax-code-v" ] || { echo "cn tag prefix wrong" >&2; exit 1; }
          [ "$MMX_REGION_DOMAIN" = "https://agent.minimax.cn" ] || { echo "cn domain wrong" >&2; exit 1; }
          ;;
        overseas)
          [ "$MMX_APP_ID" = "com.minimax.agent" ]      || { echo "global app id wrong: $MMX_APP_ID" >&2; exit 1; }
          [ "$MMX_PKG_NAME" = "minimax-code-global" ]  || { echo "global pkg name wrong: $MMX_PKG_NAME" >&2; exit 1; }
          [ "$MMX_INSTALL_PREFIX" = "/opt/minimax-code-global" ] || { echo "global prefix wrong" >&2; exit 1; }
          [ "$MMX_RELEASE_TAG_PREFIX" = "minimax-code-global-v" ] || { echo "global tag prefix wrong" >&2; exit 1; }
          [ "$MMX_REGION_DOMAIN" = "https://agent.minimax.io" ] || { echo "global domain wrong" >&2; exit 1; }
          ;;
      esac
      exit 0
    ) || return 1
  done
  return 0
}
run_case "9d region profiles: per-edition app id, package name, prefix, tag" case_region_profiles

case_region_unknown() {
  # lib_common.sh exits on an unknown region, so run the source in a nested
  # subshell and check its status instead of the caller's.
  if ( set -u; MMX_REGION=mars; . "$ROOT/scripts/lib_common.sh" ) >/dev/null 2>&1; then
    echo "an unknown region was accepted" >&2
    return 1
  fi
  return 0
}
run_case "9e an unknown region is rejected" case_region_unknown

# ============================================================================
# Summary
# ============================================================================
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
