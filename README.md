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
**x86-64** (and experimentally **arm64**) Linux, in `.deb` and `.rpm` format.

MiniMax Code ships only for macOS and Windows. Because it is an
[Electron](https://www.electronjs.org/) application, the bulk of it
(`app.asar` + the `resources/daemon/` agent backend) is cross-platform
JavaScript. This project extracts that payload from the macOS `.dmg`, pairs it
with an official Linux Electron build of the same version, rebuilds the handful
of native addons for Linux, and wraps the result in installable packages.

## Install

Download the files for your distribution and architecture from
[Releases](../../releases) (tagged `minimax-code-v<version>`), then:

```bash
# Debian / Ubuntu / Mint / Pop!_OS
sudo apt install ./minimax-code_3.0.43_amd64.deb     # or _arm64.deb

# Fedora / RHEL / openSUSE
sudo dnf install ./minimax-code-3.0.43.x86_64.rpm     # or .aarch64.rpm
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

Requirements: `curl`, `7z` (p7zip), `perl`, `node`/`npm` (for `asar` and
`@electron/rebuild`), and [`nfpm`](https://github.com/goreleaser/nfpm)
(`go install github.com/goreleaser/nfpm/v2/cmd/nfpm@latest`).

```bash
# Produce a runnable Linux app tree from a local DMG (into build/minimax-code/):
./install.sh --dmg "MiniMax Code-3.0.43.dmg" --install-dir build/minimax-code --arch x64
./build/minimax-code/start.sh            # launch it

# Produce .deb + .rpm from a local DMG (into dist/):
PRODUCT_VERSION=3.0.43 ARCH=x64 DMG="MiniMax Code-3.0.43.dmg" ./packaging/build.sh
```

`ARCH` is `x64` or `arm`. The DMG is obtained from MiniMax's official download.

## How it works (conversion pipeline)

1. **Extract** the macOS `.dmg` with `7z` (reads the UDIF/HFS+ format).
2. **Detect** the Electron version from the app bundle's
   `Electron Framework.framework` `Info.plist` (here, 38.3.0).
3. **Extract** `Contents/Resources/app.asar` (the GUI) and merge in
   `app.asar.unpacked/` (the native addons that cannot live inside an asar).
   Copy `Contents/Resources/resources/daemon/` (the agent backend).
4. **Strip macOS-only** pieces (Squirrel updater, macOS permissions addon,
   darwin screenshot addon).
5. **Swap / rebuild native addons** for Linux: rebuild `better-sqlite3` against
   the Electron headers, swap in `node-screenshots-linux-*`, stub the
   macOS-only permissions module, and verify the bundled `libnut` /
   `fs-native-extensions` prebuilds match Electron's Node ABI.
6. **Download** the official Linux Electron runtime of the detected version and
   place the converted payload under `resources/app/`.
7. **Wrap** the result with a self-locating `start.sh` launcher and package it
   with `nfpm`.

See [the implementation plan](docs) (and the in-tree scripts) for details.

## Disclaimer & license

MiniMax Code is proprietary to MiniMax. The packaging scripts, templates,
build tooling, and CI in this repository are MIT-licensed (see
[LICENSE](LICENSE)). "MiniMax" and "MiniMax Code" are trademarks of MiniMax,
used here for identification only.
