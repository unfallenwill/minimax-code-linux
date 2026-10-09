#!/usr/bin/env node
// Minimal Linux adaptation patches for the extracted MiniMax Code main bundle.
//
// These are small, surgical, idempotent edits to make the macOS-origin app
// behave on Linux. We deliberately avoid importing any upstream "patch
// framework" — each transform is a literal, commented change to a known file.
//
// Usage: node patch_linux.js <path-to-extracted-app-dir>
"use strict";
const fs = require("node:fs");
const path = require("node:path");

const root = process.argv[2];
if (!root || !fs.existsSync(root)) {
  console.error("[patch] usage: patch_linux.js <app-dir>");
  process.exit(2);
}
const log = (m) => console.error("[patch] " + m);
let changed = 0;

// patchFile(rel, [[name, regex, replacement], ...]) — applies each transform once.
// A transform may be [name, regex, replacement, doneRegex]: when doneRegex is
// provided and already matches the file, the transform is skipped, which keeps
// re-runs idempotent even if `regex` would otherwise keep matching.
function patchFile(rel, transforms) {
  const f = path.join(root, rel);
  if (!fs.existsSync(f)) { log("skip (missing): " + rel); return; }
  let s = fs.readFileSync(f, "utf8");
  const orig = s;
  for (const [name, re, repl, done] of transforms) {
    if (done && done.test(s)) { log(rel + ": " + name + " (already applied)"); continue; }
    if (re.test(s)) { s = s.replace(re, repl); log(rel + ": " + name); changed++; }
  }
  if (s !== orig) fs.writeFileSync(f, s);
}

// 1) Login & onboarding windows are fixed-size on macOS (resizable: false). On
//    Linux a non-resizable window is also non-maximizable, so "maximize" does
//    nothing. Make them resizable so they can be maximized/restored.
patchFile("dist/main/windows/loginWindow.js", [
  ["login resizable:false -> true", /resizable:\s*false/, "resizable: true"],
]);
patchFile("dist/main/windows/onboardingWindow.js", [
  ["onboarding resizable:false -> true", /resizable:\s*false/, "resizable: true"],
]);

// 3) Rewrite the app's package.json "name". On Linux the Chromium Wayland
//    app_id (and the X11 WM_CLASS captured at process startup) lock to the
//    INITIAL app.name, which defaults to package.json#name. The upstream value
//    "@mmx-agent/electron" therefore becomes the app_id, so GNOME/KDE cannot
//    associate the window with our .desktop (which keys off StartupWMClass and
//    the desktop-file basename). The visible symptom is a generic gear icon in
//    the taskbar plus a "@mmx-agent/electron" tooltip. Neither app.setName()
//    (runs after the id is locked) nor the electron `--class` flag (ignored by
//    ozone-wayland) can override it, so the package name itself is the only
//    lever. This does NOT change userData: main/index.js calls setName("MiniMax")
//    before getPath("userData"), so the data dir stays ~/.config/MiniMax.
//    $2 (argv[3]) = the linux package id (defaults to "minimax-code").
const pkgName = process.argv[3] || "minimax-code";
patchFile("package.json", [
  [`package name -> "${pkgName}" (Wayland app_id / X11 WM_CLASS)`,
   /"name":\s*"@mmx-agent\/electron"/,
   `"name": "${pkgName}"`],
]);

// 4) Tray context menu. Upstream avoids setContextMenu (it intercepts
//    left-click on macOS) and instead binds `right-click` to popUpContextMenu.
//    That breaks on Linux: under StatusNotifierItem (AppIndicator on GNOME,
//    native on KDE) the shell renders the tray menu itself and never forwards
//    right-click to the app, so with setContextMenu(null) no menu appears at
//    all. This is a Linux-only package, so just register the menu via
//    setContextMenu; left-click still fires 'click' (bring-to-front) below.
patchFile("dist/main/modules/tray/index.js", [
  ["tray: setContextMenu so the Linux shell renders the menu",
   /\/\/[^\n]*\n(\s*)t\.setContextMenu\(null\);/,
   "// Linux: the shell (SNI / AppIndicator on GNOME, native on KDE) renders the\n" +
   "$1// tray menu itself and never forwards right-click to the app, so register it\n" +
   "$1// via setContextMenu. Left-click still fires 'click' (bring-to-front) below.\n" +
   "$1t.setContextMenu(createContextMenu());"],
]);

// 5) Force app.isPackaged = true. Upstream gates two subsystems on
//    `app.isPackaged`, and both branches assume a real macOS .app bundle:
//
//    a) modules/mcode-tools/index.js picks the "resolved resource" path
//       (process.resourcesPath/resources/mcode-tools, which we DO ship) when
//       isPackaged, and otherwise runs the development-only helper
//       scripts/mcode-tools-dev-resource.mjs -- a file that exists in the
//       upstream source tree but is NOT in the packaged app. On Linux the
//       helper is absent, so every launch threw
//       "mcode-tools development resource preparation failed" and the
//       lifecycle settled on ready_degraded.
//    b) modules/local-runtime/native-sqlite-env.js#shouldUseDevNativeSqlite
//       returns true as soon as isPackaged === false, kicking off a from-
//       source rebuild of better-sqlite3 via a `prebuild-install` binary that
//       does not exist in the package -- hence the repeated
//       "prebuild-install binary not found" on each start.
//
//    Electron derives isPackaged from its own install layout, not from argv:
//    we verified on this Electron build that BOTH an unpacked resources/app/
//    directory and a resources/app.asar still report isPackaged === false,
//    because a stock Electron binary paired with an external resources tree
//    is never a "packaged app". No launcher or layout change can fix it, so
//    the flag has to be overridden in JS.
//
//    We pin it right after `require("electron")` in the main entry point,
//    which runs before any lifecycle module is imported. Every module resolves
//    `require("electron")` through the same singleton, so one defineProperty
//    covers them all. The define is configurable so re-running this script is
//    idempotent, and we skip the file entirely if the marker is already there.
//
//    Scope note: this only flips gates that assume a macOS bundle. The code
//    behind them resolves against process.resourcesPath (mcode-tools,
//    pptx-core, desktop eval capture), which we reproduce faithfully, so the
//    packaged branch is the correct one to take.
patchFile("dist/main/index.js", [
  ["force app.isPackaged = true (macOS-bundle gates: mcode-tools, dev-native sqlite)",
   /const electron_1 = require\("electron"\);\n/,
   (m) => m +
     '// Linux (unofficial build): Electron reports isPackaged === false for a\n' +
     '// stock Electron binary + external resources tree, which sends upstream\n' +
     '// down macOS-dev-only branches (mcode-tools dev-resource helper and the\n' +
     '// from-source better-sqlite3 rebuild). Neither exists in a package, so\n' +
     '// pin the flag before any lifecycle module is imported.\n' +
     'Object.defineProperty(require("electron").app, "isPackaged", { value: true, configurable: true });\n',
   /Object\.defineProperty\(require\("electron"\)\.app, "isPackaged"/],
]);

// 6) shouldUseDevNativeSqlite also fires inside the UtilityRuntime child
//    process, which patch #5 cannot reach. That process runs with
//    ELECTRON_RUN_AS_NODE=1, so `require('electron')` resolves to the module
//    PATH STRING rather than the electron module -- electron.app is therefore
//    undefined and getElectronApp() falls into its catch, returning undefined.
//    prepareLocalRuntimeNativeSqliteEnv() then bails at `!electronApp` and the
//    from-source better-sqlite3 rebuild is skipped... except the error we saw
//    came from ensureDevNativeBetterSqlite3, reached via resolveLocalRuntimeRepoRoot
//    in the *main* process too. Rather than guess which of the two processes
//    logged it, make the predicate itself return false unless we are genuinely
//    running from an app.asar: that is the only layout upstream means by
//    "packaged", and it is the one condition that cannot be true here.
patchFile("dist/main/modules/local-runtime/native-sqlite-env.js", [
  ["shouldUseDevNativeSqlite: only an app.asar app path is a packaged build",
   /function shouldUseDevNativeSqlite\(entryPoint, electronApp\) \{\n(\s*)if \(entryPoint\.kind === 'typescript'\)\n\s*return true;\n\s*if \(electronApp\.isPackaged === false\)\n\s*return true;\n\s*return !electronApp\.getAppPath\(\)\.includes\('app\.asar'\);/,
   (m, indent) =>
     "function shouldUseDevNativeSqlite(entryPoint, electronApp) {\n" +
     indent + "if (entryPoint.kind === 'typescript')\n" +
     indent + "    return true;\n" +
     indent + "// Linux (unofficial build): this package ships resources/app/ as an\n" +
     indent + "// unpacked directory, and the UtilityRuntime child cannot read\n" +
     indent + "// electron.app at all (ELECTRON_RUN_AS_NODE makes require('electron')\n" +
     indent + "// return a path string). Both cases made us attempt a from-source\n" +
     indent + "// better-sqlite3 rebuild that needs prebuild-install, which this\n" +
     indent + "// package does not ship. better-sqlite3 is already installed for\n" +
     indent + "// Electron/linux by install.sh, so only a real app.asar counts.\n" +
     indent + "return Boolean(electronApp?.getAppPath?.().includes('app.asar'));"],
]);

// 7) computer-use (Cua Driver) platform gates.
//
//    The macOS DMG ships only @trycua/cua-driver-darwin-*, but upstream PUBLISHES
//    a Linux build (cua-driver-linux-x64-gnu) and its own resolveLibPath() already
//    resolves linux-<arch>-<libc> -- so the driver itself is not the blocker; it is
//    these allowlists. Four modules bail out on anything that is not darwin/win32,
//    which silently disables the pointer, the click overlay, element_token
//    coordinate targeting, and window handoff. Adding 'linux' to each allowlist
//    re-enables them.
//
//    Deliberately NOT touched:
//      - cua-launch-observation.js / cua-preview.js  : macOS-only preview capture.
//      - cua-utility-server.js `platform !== 'darwin'` blocks at 490/512/678 :
//        version/os-specific macOS 24 workarounds, not platform gating. Relaxing
//        them would apply a macOS fix on Linux.
//      - cua-utility-server.js modifier mapping : already correct on Linux
//        (platformPrimaryModifier() returns 'ctrl').
for (const rel of [
  "dist/main/modules/local-runtime/computer-use/cua-pointer.js",
  "dist/main/modules/local-runtime/computer-use/cua-overlay.js",
  "dist/main/modules/local-runtime/computer-use/cua-pointer-target.js",
  "dist/main/modules/local-runtime/computer-use/cua-window-handoff.js",
]) {
  patchFile(rel, [
    ["allow linux in the computer-use platform allowlist",
     /\['(darwin|win32)', '(win32|darwin)'\]\.includes\((process\.platform|this\.platform)\)/,
     (_m, a, b, p) => `['${a}', '${b}', 'linux'].includes(${p})`],
  ]);
}

log(changed ? `done (${changed} transform(s))` : "no changes needed");
