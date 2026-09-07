# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Versions describe **this wrapper**, not the Project Zomboid version it runs.

## [Unreleased]

### Added

- **The published images are scanned again every night.** Trivy ran once, at
  publish time, and never looked at the image afterwards, so a vulnerability
  disclosed the week after a release stayed invisible for as long as that
  release was the current one. A separate `Scan published` workflow now pulls
  each `latest` tag from the registry and scans what is actually there. Its own
  workflow and badge on purpose: a red `Test` means the game broke the image, a
  red `Scan published` means a package in a shipped image grew a CVE.
- **`govulncheck` runs on every pull request**, through the same pinned Go
  toolchain as the release build. It is reachability-aware, so it reports a
  vulnerability only when the affected symbol can actually be called from this
  code. Trivy finds a vulnerable standard library in the built image as well,
  but later and without naming the call that makes it matter.
- `tests/check-lint-versions.sh` fails when a linter version in
  `.pre-commit-config.yaml` and its counterpart in the `env:` block of
  `.github/workflows/lint.yml` disagree. Both files said they were kept in step
  and nothing checked it, while Renovate only ever updates the pre-commit side —
  so its next hook update would have moved one and left the other behind, which
  is exactly the drift the rule exists to prevent. It also fails on a pin in the
  workflow it has not been told about, so a tool added to CI cannot quietly
  escape the comparison. Runs in CI and as a pre-commit hook.

### Changed

- The server's console FIFO is created with mode 0600 instead of the image's
  default 0644. Anything able to write to it issues console commands on the
  server; only uid 1000 exists in the container, so this closes an intent gap
  rather than a hole.
- The bats runner image runs as an unprivileged user. It is never published, so
  the misconfiguration it carried was not an exposure — it was simply the one
  finding standing between `trivy config .` and a clean run, and a scanner with
  a permanently expected failure is one people stop reading.

### Fixed

- **The monitoring overlay put RCON on the shared monitoring network.**
  `docker-compose.monitoring.yml` joined `pz-server` to that network
  unconditionally, so port 27015 — full administration of the game server — and
  the two UDP game ports were reachable from every container in the monitoring
  stack, whether or not the JVM metrics were switched on. `docker-compose.yml`
  promises the opposite in as many words. Only the exporter joins now; the
  server does so through the new `docker-compose.monitoring-jvm.yml`, which is
  what `PZ_JMX_METRICS=true` actually needs, and which says what it costs.
- **CI's shellcheck and shfmt runs skipped the bats suite.** Both matched
  `*.sh`, while the pre-commit hooks match shell by type and have always covered
  `tests/unit/*.bats`. A local hook stricter than CI is the same problem as a
  local hook on a different version: which run you believe depends on which one
  you happened to trigger. Both now include `*.bats`.
- **A failed ntfy notification did not say why.** `curl`'s own error text was
  discarded, so a rejected token and an unreachable host logged the same
  sentence. The warning now carries it. The authorization header is built as an
  array while here, like every other command line in this codebase, which
  retires a `shellcheck disable`; the word splitting that suppression covered
  turned out not to happen — bash honours the quotes inside `${VAR:+...}`, so a
  token containing a space or a star was never split or globbed.
- **Workflow runs were not serialised.** Two pushes to `main` in quick
  succession started two releases that raced for the `edge` tag, and the winner
  was whichever finished last rather than whichever was newer. Re-pushing to a
  pull request branch also paid for the 7 GB smoke test twice for one answer.
  Lint and Test now cancel a superseded run. Release queues instead of
  cancelling, because a publish killed between two of its three matrix jobs
  would leave the images at different commits.
- **CI never linted `Dockerfile.exporter`.** The hadolint step worked from a
  hand-written list that the file was never added to, so the exporter image
  definition could be changed without hadolint ever seeing it. The local
  pre-commit hook did cover it, which is why the gap stayed quiet: the two never
  disagreed out loud. The list is now derived from the working tree, and every
  Dockerfile is linted before the step fails.
- **The stack test reported a truncated metrics fetch as a broken JMX agent.**
  `curl` streams to stdout, so a transfer that dies part way through leaves a
  partial body behind; the test discarded curl's exit status, so that body looked
  complete. `jvm_memory_used_bytes` sits in the last 6% of the agent's output, so
  a cut-off response kept every earlier `jvm_` family and lost exactly the one
  being asserted — which reads precisely like an agent that never loaded. That is
  how an unchanged commit went from green to red overnight. Both metrics fetches
  now check the exit status and retry a slow scrape, and the failure message says
  which of the two problems actually occurred.

## [1.2.0] - 2026-09-06

### Added

- A metrics exporter, published as
  `ghcr.io/swatpeacekeeper/zomboid-server-docker-exporter`, built `FROM scratch`
  so it carries no packages and therefore no package vulnerabilities. It reports players
  online, backup health, server reachability and the installed Steam build id on
  port 9401. It only reads: RCON queries plus two read-only volume mounts.
  Container CPU and memory are deliberately not exported, because cAdvisor
  already produces them and two sources for one number disagree eventually.
- Optional JVM metrics through the Prometheus JMX agent, enabled with
  `PZ_JMX_METRICS=true`. Off by default: it loads third-party code into the
  game's JVM and opens a listener.
- A Grafana dashboard in `grafana/pz-dashboard.json` and a
  `docker-compose.monitoring.yml` overlay for attaching to an existing monitoring
  network.
- The backup sidecar writes `${BACKUP_DIR}/.status` after every run, recording
  `ok`, `failed` or `skipped`. Without it a failed backup was invisible from
  outside the container: files show what exists, not what is missing.

### Fixed

- **The stack test was verifying released images instead of the code under
  test.** The services carry both `image:` and `build:`, and Compose's default
  pull policy prefers the published image, so `docker compose up -d` ran the last
  release. Every previous stack run proved less than it appeared to. The test now
  forces `--build`.
- The README claimed Compose builds locally on first run, which was wrong for the
  same reason, and told people to use `--build` only after editing. It now says
  to use it whenever you intend to change anything.

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

[Unreleased]: https://github.com/SWATPeaceKeeper/zomboid-server-docker/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/SWATPeaceKeeper/zomboid-server-docker/compare/v1.1.1...v1.2.0
[1.1.1]: https://github.com/SWATPeaceKeeper/zomboid-server-docker/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/SWATPeaceKeeper/zomboid-server-docker/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/SWATPeaceKeeper/zomboid-server-docker/releases/tag/v1.0.0
