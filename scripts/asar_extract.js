// Tolerant asar extractor for the MiniMax Code Linux build.
//
// The official macOS DMG sometimes ships an asar whose `app.asar.unpacked/`
// directory is missing files that the asar header still marks as unpacked.
// This happens most often when the DMG is a Universal/darwin-x64 build: the
// header lists darwin-arm64 and win32-* unpacked entries, but only darwin-x64
// files actually exist next to app.asar. The stock `npx asar extract` fails
// the whole extraction on the first ENOENT, leaving us without a node_modules
// tree at all.
//
// Strategy:
//   - Walk the header ourselves instead of `asar extractAll`.
//   - For each file, pick the best source we can actually read:
//       1. the disk-side unpacked copy (if it exists)
//       2. the archive payload itself (entry has a numeric `offset`)
//       3. otherwise skip with a warning
//   - Symlinks are recreated as symlinks; directories as mkdir.
//   - Emit a one-line summary at the end so the CI log shows what was skipped.
//
// Usage: node asar_extract.js --asar <app.asar> --out <dir> [--unpacked-root <dir>]
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const asar = require("@electron/asar");

function parseArgs(argv) {
  const out = {};
  for (let i = 2; i < argv.length; i++) {
    const k = argv[i];
    if (!k.startsWith("--")) continue;
    out[k.slice(2)] = argv[++i];
  }
  return out;
}

const args = parseArgs(process.argv);
const ASAR = args.asar;
const OUT = args.out;
const UNPACKED_ROOT = args["unpacked-root"];
if (!ASAR || !OUT) {
  console.error("usage: asar_extract.js --asar <app.asar> --out <dir> [--unpacked-root <dir>]");
  process.exit(2);
}

const HEADER = JSON.parse(asar.getRawHeader(ASAR).headerString);
const ARCHIVE_DIR = path.dirname(ASAR);

let copied = 0, extracted = 0, skipped = 0;
const skippedFiles = [];

function ensureDir(p) {
  fs.mkdirSync(p, { recursive: true });
}

function copyFromUnpacked(unpackedField, asarRelPath) {
  // asar header convention: `unpacked: true` => file lives at
  //   app.asar.unpacked/<same path as in the archive>
  // `unpacked: "<rel>"` => file lives at app.asar.unpacked/<rel>.
  if (!UNPACKED_ROOT) return null;
  const rel = typeof unpackedField === "string" ? unpackedField : asarRelPath;
  const onDisk = path.join(UNPACKED_ROOT, rel);
  // Refuse directories masquerading as files (EISDIR on copyFile).
  if (fs.existsSync(onDisk) && fs.statSync(onDisk).isFile()) return onDisk;
  return null;
}

function inArchive(entry) {
  // Unpacked entries carry size+integrity but no offset; only on-disk copies.
  return typeof entry.offset === "string" || typeof entry.offset === "number";
}

function emitFile(relPath, entry) {
  const dest = path.join(OUT, relPath);
  ensureDir(path.dirname(dest));

  const diskSrc = copyFromUnpacked(entry.unpacked, relPath);
  if (diskSrc) {
    fs.copyFileSync(diskSrc, dest);
    copied++;
    return;
  }

  if (inArchive(entry)) {
    const buf = asar.extractFile(ASAR, relPath);
    fs.writeFileSync(dest, buf);
    extracted++;
    return;
  }

  // File is referenced (unpacked) but neither on disk nor in archive.
  // This is the 3.0.51 darwin-arm64 / win32-* case — harmless on Linux.
  skipped++;
  skippedFiles.push(relPath);
}

function walk(node, base) {
  for (const [name, child] of Object.entries(node.files || {})) {
    const rel = base ? base + "/" + name : name;
    if (child.files) {
      ensureDir(path.join(OUT, rel));
      walk(child, rel);
      continue;
    }
    if (child.link) {
      ensureDir(path.join(OUT, path.dirname(rel)));
      const target = path.join(OUT, child.link);
      const dest = path.join(OUT, rel);
      try { fs.unlinkSync(dest); } catch {}
      fs.symlinkSync(target, dest);
      continue;
    }
    emitFile(rel, child);
  }
}

fs.rmSync(OUT, { recursive: true, force: true });
ensureDir(OUT);
walk(HEADER, "");

console.error(`[asar-extract] copied=${copied} extracted=${extracted} skipped=${skipped}`);
if (skipped > 0) {
  // Cap the list so a heavily-broken archive doesn't spam the log.
  const show = skippedFiles.slice(0, 20);
  for (const f of show) console.error(`[asar-extract] skip: ${f}`);
  if (skippedFiles.length > show.length)
    console.error(`[asar-extract] ... and ${skippedFiles.length - show.length} more`);
}
// A non-zero skip count is not a failure: those files are unreachable on the
// host platform anyway. Hard-fail only on the rare case of 0 files extracted.
if (extracted + copied === 0) {
  console.error("[asar-extract] no files extracted — refusing to proceed");
  process.exit(1);
}