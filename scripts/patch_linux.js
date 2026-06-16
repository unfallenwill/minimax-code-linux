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

log(changed ? `done (${changed} transform(s))` : "no changes needed");
