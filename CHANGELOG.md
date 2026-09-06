# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Versions describe **this wrapper**, not the Project Zomboid version it runs.

## [Unreleased]

## [1.1.1] - 2026-09-06

### Fixed

- **The Compose stack could not install the server at all.** `pz-internal` was
  declared `internal: true`, which has no route out, so SteamCMD died with
  "Steamcmd needs to be online to update" and the documented quick start never
  worked. RCON is kept off the internet by not publishing its port, which is what
  was already happening — cutting the containers off from the network as well was
  both unnecessary and fatal.
- A fresh deployment no longer opens with an error. The startup backup ran before
  the server had created a world and reported "Startup backup failed", which was
  alarming and wrong. Having nothing to back up yet is now reported as a skip;
  real failures are unchanged.

### Added

- `tests/compose-network.sh`, run in CI, starts a container on the Compose
  network and checks it can reach the internet. The image smoke test structurally
  cannot catch this: it uses `docker run` on the default bridge and never touches
  the Compose network.

### Changed

- The README is now a complete guide: requirements, two ways to start, what the
  first boot looks like, how players connect, admin access, day-to-day
  operations, editing sandbox settings, running several servers, and
  troubleshooting.

## [1.1.0] - 2026-09-06

### Added

- The release workflow now pulls the image it just pushed and runs the full
  end-to-end smoke test against it. Until now the smoke test only ever ran
  against a locally rebuilt image: same source, different build, so the artefact
  people actually pull had never been started by CI.
- `tests/smoke.sh` accepts `SMOKE_SKIP_BUILD=true`, which pulls `SMOKE_IMAGE`
  instead of building it and prints the digest under test.

### Changed

- `latest` now moves only when a version is tagged. It was previously applied on
  every push to `main`, which made it a second name for `edge` and contradicted
  what the README promised it meant.
- Workflow permissions in the release pipeline are granted per job. `packages:
  write` is limited to the publishing job; the verification job only reads.

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

[Unreleased]: https://github.com/SWATPeaceKeeper/zomboid-server-docker/compare/v1.1.1...HEAD
[1.1.1]: https://github.com/SWATPeaceKeeper/zomboid-server-docker/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/SWATPeaceKeeper/zomboid-server-docker/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/SWATPeaceKeeper/zomboid-server-docker/releases/tag/v1.0.0
