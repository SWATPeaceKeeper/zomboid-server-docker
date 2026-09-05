# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Versions describe **this wrapper**, not the Project Zomboid version it runs.

## [Unreleased]

## [1.0.0] - 2026-09-05

First stable release. The container and Compose stack are complete and verified
end to end: the smoke test starts a real server, waits for it to accept players,
saves over RCON and stops it cleanly, and it runs on every pull request and
nightly.

### Added

- Server image based on `steamcmd/steamcmd:ubuntu-24`, pinned by digest, running
  as uid/gid 1000. Steam app `380870` is installed into a volume on first start
  rather than baked into the image, so the game branch is switchable at runtime
  and no Steam content is redistributed.
- Graceful shutdown: the server's stdin is a FIFO, `SIGTERM` writes `quit` into it
  and waits for the world to be saved.
- Hybrid configuration: a fixed set of operational keys is patched into
  `<SERVER_NAME>.ini` on every start; every other key, and all of
  `SandboxVars.lua`, is left untouched.
- Runtime branch selection through `PZ_BRANCH` (`public` for Build 42,
  `legacy41` for Build 41).
- JVM heap configured through `PZ_MAX_RAM`, written only into
  `ProjectZomboid64.json`.
- Workshop mod configuration through `MOD_IDS` and `WORKSHOP_IDS`, with a warning
  when Build 42 mod ids are missing their leading backslash.
- Healthcheck that queries the server over RCON, with a process and socket
  fallback when RCON is not configured.
- Backup sidecar with scheduled, on-start and manual backups, `tar` and
  borg-friendly `dir` modes, rotation, and optional ntfy notification.
- Compose stack that keeps RCON on an internal network and publishes only the two
  UDP game ports.
- CI: bats unit tests, an end-to-end smoke test that starts a real server, a
  nightly run, linting at versions identical to the pre-commit hooks, Trivy
  scanning and publication to GHCR.

### Security

- `rcon-cli` is compiled from its tagged source with a current Go toolchain
  instead of being taken from the upstream release tarball. That tarball was
  built in 2023, and the Go standard library baked into it carries 41
  HIGH/CRITICAL advisories that no base image update can remove. Both images now
  scan clean.

[Unreleased]: https://github.com/SWATPeaceKeeper/zomboid-server-docker/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/SWATPeaceKeeper/zomboid-server-docker/releases/tag/v1.0.0
