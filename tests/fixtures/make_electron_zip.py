#!/usr/bin/env python3
"""Offline test fixture (tests/run.sh): build a minimal "Electron" zip.

The archive contains an executable `electron` plus a few filler members, so
lib_electron.sh's post-unpack check (`[ -x .../electron ]`) passes. Executable
bits are encoded in each member's external_attr so real `unzip` restores them.
"""
import sys
import zipfile

MEMBERS = [
    ("electron", b"#!/bin/sh\necho electron-stub\n", 0o755),
    ("chrome_crashpad_handler", b"#!/bin/sh\n", 0o755),
    ("resources/default_app.asar", b"stub\n", 0o644),
    ("LICENSES.chromium.html", b"stub\n", 0o644),
]

def main() -> None:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <out.zip>", file=sys.stderr)
        raise SystemExit(2)
    with zipfile.ZipFile(sys.argv[1], "w") as z:
        for name, data, mode in MEMBERS:
            zi = zipfile.ZipInfo(name, date_time=(2024, 1, 1, 0, 0, 0))
            zi.external_attr = (mode | 0o100000) << 16  # regular file + perms
            z.writestr(zi, data)
    print(sys.argv[1])

if __name__ == "__main__":
    main()
