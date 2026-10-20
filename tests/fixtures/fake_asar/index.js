// Offline test fixture: a fake @electron/asar module (used by tests/run.sh).
//
// scripts/asar_extract.js only needs two APIs:
//   getRawHeader(asar) -> { headerString }   the JSON directory header
//   extractFile(asar, relPath) -> Buffer     one file's payload
// This fixture serves a small canned two-file "archive" so the full install.sh
// pipeline can run without the real @electron/asar package or a real DMG.
"use strict";
const FILES = {
  "package.json":
    JSON.stringify({ name: "@mmx-agent/electron", version: "9.9.9-test" }) + "\n",
  "dist/main/index.js":
    'const electron_1 = require("electron");\nconsole.log("stub main");\n',
};

// Upstream ships a per-edition .env.local INSIDE app.asar (it selects the
// backend host). The edition guard in install.sh reads it, so the fixture
// serves one too: the default is the CN edition, and MMX_TEST_ENV_LOCAL
// overrides the content so tests can simulate a payload from another edition.
FILES[".env.local"] =
  process.env.MMX_TEST_ENV_LOCAL !== undefined
    ? process.env.MMX_TEST_ENV_LOCAL
    : 'NEXT_PUBLIC_BUILD_ENV="prod"\nNEXT_PUBLIC_DOMAIN_URL="https://agent.minimax.cn"\nNEXT_PUBLIC_LOCALE="zh"\n';

module.exports = {
  getRawHeader() {
    const files = {};
    for (const k of Object.keys(FILES)) {
      files[k] = { offset: "0", size: Buffer.byteLength(FILES[k]) };
    }
    return { headerString: JSON.stringify({ files }) };
  },
  extractFile(_asar, rel) {
    if (!(rel in FILES)) throw new Error("no such archive entry: " + rel);
    return Buffer.from(FILES[rel], "utf8");
  },
};
