# AGENTS.md

This repository builds **unofficial Linux `.deb`/`.rpm` packages** for
MiniMax Code by converting the official macOS `.dmg`. It does **not** contain
MiniMax source code; it only repackages upstream binaries. See `NOTICE.md`.

The conversion works because MiniMax Code is an Electron app: `app.asar`
(GUI) and its bundled runtime resources are cross-platform JavaScript. The pipeline extracts them from the macOS DMG,
rebuilds the handful of native addons for Linux, pairs them with an official
Linux Electron runtime of the same version, and wraps the result with `nfpm`.

## Common commands

Requirements: `curl`, **7-Zip >= 24.01** (`7zz`, or `7z` from p7zip),
`perl`, `node`/`npm`, `python3`, `unzip`, `tar`, `file`, `strings`, and
[`nfpm`](https://github.com/goreleaser/nfpm)
(`go install github.com/goreleaser/nfpm/v2/cmd/nfpm@latest`). For `node-pty`
rebuilds: `g++`, `make`.

7-Zip 24.01+ is mandatory: upstream DMGs since 3.1.6 are XZ-compressed HFS+
(`UDIF "Zero2 XZ"`), which older p7zip builds (16.02/17.05) reject with
`Unsupported Method` and extract no `.app`. `lib_dmg.sh` picks the newest of
`7zz`/`7z` and warns when it is too old.

```bash
# Produce a runnable Linux app tree from a local DMG (into build/minimax-code/):
./install.sh --dmg "MiniMax Code-3.0.43.dmg" --install-dir build/minimax-code
./build/minimax-code/start.sh            # launch it

# Produce .deb + .rpm from a local DMG (into dist/):
PRODUCT_VERSION=3.0.43 ARCH=x64 DMG="MiniMax Code-3.0.43.dmg" ./packaging/build.sh

# Discover the latest upstream version + DMG URL (prints "<version>\n<url>"):
./packaging/resolve-version.sh
```

`ARCH` is `x64` or `arm` (maps to `amd64`/`arm64` deb, `x86_64`/`aarch64` rpm).
`tests/run.sh` exercises the shell stages (resolver, DMG helpers, native
packaging API, repo-cleanliness) and is the closest thing to a test suite.
There is no linter; end-to-end verification still means installing the produced
package and launching the app.

## CI

`.github/workflows/build.yml` is the only meaningful workflow:

- **schedule (every 6h)**: `discover` job runs `resolve-version.sh`; if the
  resolved version does not already exist as a `minimax-code-v<version>` GitHub
  Release, it dispatches a `workflow_dispatch` build. The release tag set is
  the source of truth for "what has been packaged".
- **workflow_dispatch**: builds one arch for one version (`version` + `arch` +
  optional `dmg_url`), uploads to a `minimax-code-v<version>` release.
- **keepalive.yml**: weekly no-op commit so GitHub does not disable the cron.

CI installs `perl file python3 unzip xz-utils` via apt, the official 7-Zip
`7zz` console build (pinned in `build.yml`, currently 26.00) from 7-zip.org,
and `nfpm` via `go install`.

## Architecture: the conversion pipeline

`install.sh` is the orchestrator. It sources bash libraries from `scripts/`
in order; each library owns one stage. Read `install.sh` first, then the
relevant `lib_*.sh` for the stage you are changing.

```
install.sh
  └── scripts/lib_common.sh   constants (MMX_* env), logging (info/warn/die), arch mapping
      scripts/lib_dmg.sh       DMG resolve/download, 7zz/7z extract, Electron + app version detection
      scripts/lib_asar.sh      tolerant app.asar extraction (ships unpacked resources/app/)
       └── scripts/asar_extract.js   Node walker; tolerates missing app.asar.unpacked entries
      scripts/patch_linux.js   surgical Linux adaptation patches to extracted app/ JS
      scripts/lib_native_*.sh  native addon swap/rebuild/stub (see below)
      scripts/lib_electron.sh  download + unpack official Linux Electron runtime
  launcher/start.sh.template   copied verbatim as start.sh beside electron binary
```

Output layout (reproduces the macOS `process.resourcesPath` so no path overrides
are needed at runtime):

```
<install-dir>/
  electron                      # official Linux Electron of detected version
  chrome-sandbox                # chmod 4755 at package install (postinst)
  start.sh                      # self-locating launcher (wrapper at /usr/bin)
  resources/
    app/                        # extracted app.asar (GUI), Linux-patched
      node_modules/             # native addons rebuilt/swapped for Linux
    resources/resources/        # mcode-tools, pptx-core, session-transfer, ...
                                # (the agent runtime lives in app/node_modules/@mavis/local-runtime)
  build-info.json               # version/electron/arch/app_id metadata
```

### Native addon handling (`scripts/lib_native_*.sh`)

This is the most fragile stage and where most version-bump breakage happens.
Each bundled native module needs a different strategy; the per-module comments
in `lib_native_strip.sh` / `lib_native_pkgs.sh` / `lib_native_build.sh` are the
authoritative reference. Summary:

| Module | Strategy |
| --- | --- |
| `better-sqlite3` | Bundled stripped + darwin `.node`. **Reinstall** full package built against Electron headers (isolated temp project). |
| `node-screenshots` | Bundled darwin only. **Swap** in `node-screenshots-linux-<arch>-<libc>` (N-API, ABI-stable). |
| `@nut-tree/libnut-linux`, `fs-native-extensions` | N-API prebuilds load OK. **Untouched**. |
| `@nut-tree/node-mac-permissions` | macOS-only TCC API. **Stub** with a no-op `Proxy` shim. |
| `@mariozechner/clipboard`, `@vscode/ripgrep` | Bundled darwin subpackages only. **Install** the linux platform package from npm at the pinned version. |
| `node-pty` | No linux prebuilds at all. **Build from source** against Electron headers (`pty.node` via node-gyp) + compile `spawn-helper` with `g++` (binding.gyp only registers it on macOS, but `pty.cc` execvp()s it unconditionally on Linux). |

There is no opencode binary to swap: the agent runtime is the pure-JS
`@mavis/local-runtime` under `resources/app/node_modules`. The addon passes are
applied once, to `GUI_ROOT=resources/app/node_modules`.

**Forward-only:** the pipeline targets the current upstream release. There is no
backward compatibility for older upstream versions or retired internal APIs -
delete shims rather than keeping them.

### Linux adaptation patches (`scripts/patch_linux.js`)

Idempotent literal regex transforms to the extracted JS. Each transform is
commented with *why* it is needed. Current set:

1. `loginWindow.js` / `onboardingWindow.js`: `resizable: false` -> `true`
   (non-resizable windows cannot be maximized on Linux).
2. `package.json`: rewrite `"name": "@mmx-agent/electron"` to the package id
   (default `minimax-code`). This is the only lever for the Wayland `app_id` /
   X11 `WM_CLASS`, which locks at process startup from `package.json#name`.
   `app.setName()` runs too late; the `--class` flag is ignored by
   ozone-wayland. Does **not** change `userData` (main/index.js calls
   `setName("MiniMax")` before `getPath("userData")`).
3. `dist/main/modules/tray/index.js`: replace `setContextMenu(null)` +
   `right-click` handler with `setContextMenu(createContextMenu())`. Under
   StatusNotifierItem (GNOME AppIndicator, native KDE) the shell renders the
   tray menu itself and never forwards right-click, so without
   `setContextMenu` no menu appears at all.

### Version resolution (`packaging/resolve-version.sh`)

Prints `<version>\n<dmg-url>`. Two independent sources are queried and the
**highest version whose DMG passes a HEAD check wins** (never first-match):

1. electron-updater `latest-mac.yml` in the release directory
   (`https://filecdn.minimax.chat/public/minimax-agent-prod/release/` for CN,
   `https://file.cdn.minimax.io/public/minimax-agent-prod/release/` for
   `MMX_REGION=overseas`). This is authoritative and published at release time.
2. MiniMax `common_config` JSON (`MMX_CONFIG_URL`, default the CN endpoint)
   `data.agent_config` -> `cnX64MacosDownloadUrl` / `overseasX64MacosDownloadUrl`.
   **This lags** (it advertised 3.1.6 for days after 3.1.7 shipped), so it can
   only win when it is actually newer.

`resolve-version.sh <version>` resolves the asset for one explicit version
(synthesizing the canonical CDN name if needed), which keeps a
`workflow_dispatch` build from pairing version X with a newer DMG. The x64 DMG
payload is arch-independent and is reused for both x64 and arm64 Linux builds.

CI's `discover` job treats an unresolvable version as a failure (it used to
silently skip), so a broken source shows up instead of stalling releases.

### Packaging (`packaging/build.sh` + `packaging/templates/`)

`build.sh` runs `install.sh` into `build/payload`, then renders the `*.tmpl`
files with perl `${VAR}` expansion (not a real template engine) and invokes
`nfpm package` for both deb and rpm. Templates declare runtime library deps
(GTK3, NSS, ALSA, X11/XCB, libsecret, at-spi2, mesa-libgbm, xdg-utils) per
distro family. `postinst` chmods `chrome-sandbox` to 4755 (setuid root) -
without this the app will not start on most distros.

## Overridable identity (env, see `scripts/lib_common.sh`)

- `MMX_APP_ID` (default `com.minimax.agent.cn`) - the CN edition; set to the
  overseas bundle id for the overseas edition.
- `MMX_PKG_NAME` / `MMX_DISPLAY` / `MMX_WMCLASS` / `MMX_BIN` (default
  `minimax-code` / `MiniMax Code` / `minimax-code` / `minimax-code`).
- `MMX_INSTALL_PREFIX` (default `/opt/minimax-code`).
- `MMX_LIBC` (default `gnu`; set `musl` for Alpine).
- `MMX_UPSTREAM_DMG_URL` - CI auto-download; empty requires `--dmg`.
- `MMX_CACHE_DIR` (default `~/.cache/minimax-code-linux`) - Electron + DMG cache.
- `MMX_ELECTRON_FALLBACK` (default `38.3.0`) - used if framework plist detection fails.

## Conventions

- Bash libraries are **sourced**, never executed directly. `set -Eeuo pipefail`
  is the norm; `die`/`warn`/`info` go to stderr.
- Ship the app as an **unpacked `resources/app/`** directory, not a repacked
  `app.asar`. Electron loads both identically and there is no macOS-style asar
  integrity binding on a stock Linux Electron build.
- Patches in `patch_linux.js` must be **idempotent** and log each applied
  transform; missing files are skipped, not fatal.
- `build/` and `dist/` are gitignored build outputs. Never commit a `.dmg`.
