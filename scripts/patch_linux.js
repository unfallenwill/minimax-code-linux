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
function patchFile(rel, transforms) {
  const f = path.join(root, rel);
  if (!fs.existsSync(f)) { log("skip (missing): " + rel); return; }
  let s = fs.readFileSync(f, "utf8");
  const orig = s;
  for (const [name, re, repl] of transforms) {
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

log(changed ? `done (${changed} transform(s))` : "no changes needed");
