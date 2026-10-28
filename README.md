# MiniMax Code — unofficial Linux packages (.deb / .rpm)

> ⚠️ **Unofficial.** This project is **not** affiliated with, endorsed by, or
> sponsored by **MiniMax**. **MiniMax Code is © MiniMax.** The packages here are
> built from the **official macOS build** by extracting its cross-platform
> payload and running it under the matching Linux Electron runtime. See
> [NOTICE.md](NOTICE.md). If anything here should not be distributed this way,
> please open an issue.

Official product: <https://agent.minimax.io>

This repository produces **unofficial Linux packages** for
[MiniMax Code](https://agent.minimax.io) — MiniMax's AI coding agent — for
**x86-64** Linux, in `.deb` and `.rpm` format.

MiniMax Code ships only for macOS and Windows. Because it is an
[Electron](https://www.electronjs.org/) application, the bulk of it
(`app.asar` plus its bundled runtime resources) is cross-platform JavaScript. This project extracts that payload from the macOS `.dmg`, pairs it
with an official Linux Electron build of the same version, rebuilds the handful
of native addons for Linux, and wraps the result in installable packages.

## Install

Download the files for your distribution and architecture from
[Releases](../../releases) (tagged `minimax-code-v<version>`), then:

```bash
# Debian / Ubuntu / Mint / Pop!_OS
sudo apt install ./minimax-code_3.0.43_amd64.deb

# Fedora / RHEL / openSUSE
sudo dnf install ./minimax-code-3.0.43.x86_64.rpm
```

Launch from your application menu, or run `minimax-code` in a terminal. Verify
downloads against the `checksums_*.txt` file in each release.

> The first run may need to install or update the agent's CLI/runtime; follow
> any in-app prompts.

## What the packages do

- Install the app under `/opt/minimax-code` with a `/usr/bin/minimax-code`
  launcher, a `.desktop` entry, and hicolor icons.
- Bundle a Linux Electron runtime and the converted MiniMax Code payload.
- Set the Electron `chrome-sandbox` to setuid root (`chmod 4755`) on install —
  without this the app will not start on most distributions.
- Declare the runtime library dependencies so the package manager pulls in what
  Electron needs (GTK, NSS, ALSA, X11/XCB, etc.).

**Updates:** install a newer package. System-wide installs do not rely on the
app's built-in macOS/Windows auto-updater.

## How new versions get packaged

A GitHub Actions workflow (see [`.github/workflows/build.yml`](.github/workflows/build.yml))
runs on a schedule, discovers the latest MiniMax Code version, and — if that
version is not already released — builds packages for both architectures and
publishes them to a GitHub Release tagged `minimax-code-v<version>`.

The "is it released?" check uses the release tag as the source of truth: each
successful build creates `minimax-code-v<version>`, so the set of tags is the
record of what has been packaged. A build can also be triggered manually with
`workflow_dispatch` (optionally pasting an explicit DMG URL).

## Build locally

Requirements: `curl`, `7z` (p7zip), `perl`, `python3`, `node`/`npm` (for
`asar` and native-addon work), and [`nfpm`](https://github.com/goreleaser/nfpm)
(`go install github.com/goreleaser/nfpm/v2/cmd/nfpm@latest`).

```bash
# Produce a runnable Linux app tree from a local DMG (into build/minimax-code/):
./install.sh --dmg "MiniMax Code-3.0.43.dmg" --install-dir build/minimax-code
./build/minimax-code/start.sh            # launch it

# Produce .deb + .rpm from a local DMG (into dist/):
PRODUCT_VERSION=3.0.43 DMG="MiniMax Code-3.0.43.dmg" ./packaging/build.sh
```

`ARCH` is `x64`. The DMG is obtained from MiniMax's official download.

Both entry points are **non-destructive on failure**: arguments and the output
directory are validated up front (dangerous targets such as `/`, system
directories, `$HOME`, the repository itself or its tracked directories are
refused), the build runs in a same-filesystem staging directory next to the
target, and the previous output is replaced only after the build succeeds — a
failed run restores an existing installation best-effort (the publish is two
renames, not an atomic exchange). DMG and Electron downloads go through one
helper that validates downloads (and cached Electron archives) before they
enter the cache, so a failed or corrupt download never replaces a good cache
entry.

## Offline tests

```bash
./tests/run.sh
```

Regression tests for the destructive boundaries above. They run fully offline
(no network, no DMG, no GUI): `7z`/`curl`/`unzip`/`mv` are stubbed and the DMG,
`app.asar` and Electron payloads are fixtures, so the suite exercises success,
failure and old-output preservation of the real scripts. See the header of
[`tests/run.sh`](tests/run.sh) for the covered scenarios.

## How it works (conversion pipeline)

1. **Extract** the macOS `.dmg` with `7z` (reads the UDIF/HFS+ format).
2. **Detect** the Electron version from the app bundle's
   `Electron Framework.framework` `Info.plist` (here, 38.3.0).
3. **Extract** `Contents/Resources/app.asar` (the GUI) and merge in
   `app.asar.unpacked/` (the native addons that cannot live inside an asar).
   Mirror the rest of `Contents/Resources/` (mcode-tools, pptx-core,
   session-transfer, and other runtime resources).
4. **Strip macOS-only** pieces (Squirrel updater, macOS permissions addon,
   darwin screenshot addon). Native-addon handling lives in three focused
   modules: `scripts/lib_native_strip.sh` (offline strip/stub),
   `scripts/lib_native_pkgs.sh` (Linux platform packages fetched from npm),
   and `scripts/lib_native_build.sh` (addons compiled from source:
   `better-sqlite3` against the Electron headers, `node-pty`'s `pty.node` +
   `spawn-helper`, and the Go session-transfer client).
5. **Download** the official Linux Electron runtime of the detected version
   (cached and CRC-validated) and place the converted payload under
   `resources/app/`.
6. **Wrap** the result with a self-locating `start.sh` launcher and package it
   with `nfpm` (packages are staged and published only once both artifacts and
   their checksums exist).

See [the implementation plan](docs) (and the in-tree scripts) for details.

## Disclaimer & license

MiniMax Code is proprietary to MiniMax. The packaging scripts, templates,
build tooling, and CI in this repository are MIT-licensed (see
[LICENSE](LICENSE)). "MiniMax" and "MiniMax Code" are trademarks of MiniMax,
used here for identification only.
