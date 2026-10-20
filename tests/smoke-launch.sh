#!/usr/bin/env bash
#
# tests/smoke-launch.sh — assert that a built MiniMax Code payload actually
# starts on Linux.
#
#   tests/smoke-launch.sh [payload-dir]     # default: build/payload
#
# The offline suite in tests/run.sh covers the destructive boundaries of the
# build pipeline, but nothing checks that the packaged app STARTS. A package
# can build cleanly and still be broken at runtime: a native addon that cannot
# be dlopen'd, a runtime resource that is missing, a native addon built against
# the wrong Electron ABI, a payload the app cannot locate. None of that is
# visible to a build that only asserts on files.
#
# This launches the built payload under Xvfb and waits for the app's own
# lifecycle readiness signal, which the main process logs once every startup
# subsystem has initialised.
#
# Exit codes:
#   0  the app reached the ready state (or the check was skipped)
#   1  the app did not start, crashed, or reported a failed startup
#
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAYLOAD="${1:-$ROOT/build/payload}"
# How long to wait for the app to report readiness.
TIMEOUT="${MMX_SMOKE_TIMEOUT:-120}"
# When set to 1, a missing Xvfb is an error instead of a skip.
REQUIRE_XVFB="${MMX_SMOKE_REQUIRE:-0}"

log()  { printf '[smoke] %s\n' "$*"; }
skip() { printf '[smoke] SKIP: %s\n' "$*"; exit 0; }
fail() { printf '[smoke] FAIL: %s\n' "$*" >&2; exit 1; }

[ -d "$PAYLOAD" ] || fail "payload dir not found: $PAYLOAD"
# Resolve to an absolute path: the launcher is started from inside the payload
# directory, so a relative PAYLOAD (e.g. the "build/payload" CI passes) would
# otherwise resolve against the wrong directory.
PAYLOAD="$(cd "$PAYLOAD" && pwd)"

# The launcher to start: this repo's start.sh, or a bare Electron binary in a
# payload laid out like the upstream app (resources/ next to the binary).
LAUNCHER=""
for cand in "$PAYLOAD/start.sh" "$PAYLOAD/minimax-code" "$PAYLOAD/electron"; do
  if [ -x "$cand" ]; then LAUNCHER="$cand"; break; fi
done
[ -n "$LAUNCHER" ] || fail "no start.sh / minimax-code / electron launcher in $PAYLOAD (build the payload first)"

# ---------------------------------------------------------------- display ---
if ! command -v Xvfb >/dev/null 2>&1; then
  if [ "$REQUIRE_XVFB" = "1" ]; then
    fail "Xvfb is required for the launch smoke test but is not installed"
  fi
  skip "Xvfb not installed (install the 'xvfb' package, or set MMX_SMOKE_REQUIRE=1)"
fi

DISPLAY_NUM=""
for n in $(seq 90 120); do
  if [ ! -e "/tmp/.X11-unix/X$n" ] && [ ! -e "/tmp/.X${n}-lock" ]; then
    DISPLAY_NUM="$n"; break
  fi
done
[ -n "$DISPLAY_NUM" ] || fail "no free X display number in 90..120"

XVFB_PID=""
APP_PID=""
SANDBOX="$(mktemp -d)"
# Keep the real HOME: the sandbox sets HOME for the app, and restoring it
# before cleanup keeps the sandbox from looking like a live home directory.
REAL_HOME="$HOME"
cleanup() {
  # Kill by PID only: never by process name, so a running desktop session
  # (which uses the same binary name) is never touched.
  if [ -n "$APP_PID" ]; then
    kill -TERM "$APP_PID" 2>/dev/null
    sleep 1
    kill -KILL "$APP_PID" 2>/dev/null
    wait "$APP_PID" 2>/dev/null || true
  fi
  if [ -n "$XVFB_PID" ]; then
    kill -TERM "$XVFB_PID" 2>/dev/null
    sleep 1
    kill -KILL "$XVFB_PID" 2>/dev/null
    wait "$XVFB_PID" 2>/dev/null || true
  fi
  HOME="$REAL_HOME"
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

Xvfb ":$DISPLAY_NUM" -screen 0 1280x900x24 -ac >"$SANDBOX/xvfb.log" 2>&1 &
XVFB_PID=$!
export DISPLAY=":$DISPLAY_NUM"

for _ in $(seq 1 50); do
  if [ -e "/tmp/.X11-unix/X$DISPLAY_NUM" ]; then break; fi
  sleep 0.1
done
[ -e "/tmp/.X11-unix/X$DISPLAY_NUM" ] || fail "Xvfb did not come up on $DISPLAY"

# ------------------------------------------------------- isolated profile ---
# A fresh HOME keeps the smoke test from touching a real profile, and keeps
# the single-instance lock out of the way of a running desktop session.
export HOME="$SANDBOX/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_RUNTIME_DIR="$HOME/run"
export XDG_SESSION_TYPE="x11"
unset WAYLAND_DISPLAY
mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR"

# Electron prefers the Wayland backend. Under Xvfb there is no Wayland
# compositor, so force the X11 backend explicitly rather than letting the app
# fail in ozone initialisation.
LOG="$SANDBOX/app.log"
log "launching $LAUNCHER on $DISPLAY (timeout ${TIMEOUT}s)"
(
  cd "$PAYLOAD" || exit 1
  exec "$LAUNCHER" --ozone-platform=x11
) >"$LOG" 2>&1 &
APP_PID=$!

# ------------------------------------------------------------- readiness ---
# The main process logs its startup timings once every subsystem has
# initialised. "outcome":"ready" with failed_count 0 is the contract.
READY_RE='outcome"?[[:space:]]*:[[:space:]]*"ready"'
DEADLINE=$(( $(date +%s) + TIMEOUT ))
READY=0
EXITED=0
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  if grep -qE "$READY_RE" "$LOG" 2>/dev/null; then READY=1; break; fi
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    EXITED=1
    break
  fi
  sleep 1
done

if [ "$READY" != "1" ]; then
  log "---- last 40 log lines ----"
  tail -40 "$LOG" 2>/dev/null | sed 's/^/[smoke]   /'
  if [ "$EXITED" = "1" ]; then
    fail "the app exited before reporting ready"
  fi
  fail "the app did not report startup readiness within ${TIMEOUT}s"
fi

# A ready report that also carries failures is not a pass.
if grep -qE 'failed_count"?[[:space:]]*:[[:space:]]*[1-9]' "$LOG" 2>/dev/null; then
  grep -oE '"failed_count"?[[:space:]]*:[[:space:]]*[0-9]+' "$LOG" | head -1 | sed 's/^/[smoke]   /'
  fail "the app reported a failed startup subsystem"
fi

if ! kill -0 "$APP_PID" 2>/dev/null; then
  fail "the app reported ready but is no longer running (crashed after startup)"
fi

grep -oE '\{[^{}]*"outcome"[^{}]*\}' "$LOG" 2>/dev/null | head -1 | sed 's/^/[smoke]   /'
log "the app started and reported readiness"
exit 0
