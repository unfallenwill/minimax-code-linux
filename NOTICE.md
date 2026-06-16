# Notice

This project is an **unofficial, community-maintained** packaging of
**MiniMax Code** for Linux. It is **not** affiliated with, endorsed by, or
sponsored by **MiniMax** or any of its affiliates.

## Software attribution

**MiniMax Code is © MiniMax.** All rights, title, and interest in the MiniMax
Code software — including the bundled Electron application, the agent daemon,
the Mavis browser extension, and all associated assets — remain the property of
MiniMax.

What this repository distributes is **not** MiniMax's source code. The build
pipeline in this repository:

1. Takes an **official, unmodified** MiniMax Code macOS `.dmg` that a user
   obtains themselves.
2. Extracts the cross-platform JavaScript payload (the `app.asar` bundle and
   the `resources/daemon/` agent backend) — these are architecture-independent.
3. Pairs that payload with an official, unmodified **Linux Electron** runtime of
   the matching version, so the same JavaScript can run on Linux.
4. Rebuilds a small number of native Node addons for the Linux platform.
5. Wraps the result in `.deb` / `.rpm` packages for convenient installation.

No MiniMax source code is modified in ways that change its product behavior
beyond what is strictly required to run on Linux (e.g. replacing macOS-only
native binaries with their Linux equivalents).

## Trademarks

"MiniMax", "MiniMax Code", "Mavis", and related names and logos are trademarks
of MiniMax. Their use here is for identification of the upstream software only
and does not imply endorsement.

## Upstream

Official product and downloads: <https://agent.minimax.io>

If you represent MiniMax and believe anything in this repository should not be
distributed this way, please open an issue and it will be addressed promptly.

## License

The packaging scripts, templates, build tooling, and CI in this repository are
MIT-licensed (see [LICENSE](LICENSE)). The MiniMax Code binaries they package
remain under MiniMax's proprietary terms.
