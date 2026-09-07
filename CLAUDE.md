# CLAUDE.md

Guidance for Claude Code and other coding agents working in this repository.
Read this before changing anything.

## What this is

A Docker packaging of the Project Zomboid dedicated server. Three images are
built here and published to GHCR:

| Dockerfile | Image suffix | Contains |
|---|---|---|
| `Dockerfile` | `zomboid-server-docker` | The game server. SteamCMD installs the game into a volume at runtime. |
| `Dockerfile.backup` | `-backup` | Backup sidecar: RCON `save`, archive, rotate, optional ntfy notification. |
| `Dockerfile.exporter` | `-exporter` | Prometheus exporter, Go, `FROM scratch`. |

**The repository ships no game files.** Project Zomboid and SteamCMD stay
subject to their own terms; nothing from either is redistributed here.

Licence: GPL-3.0-or-later. The graceful-shutdown mechanism and the in-place INI
patching are adapted from
[Danixu/project-zomboid-server-docker](https://github.com/Danixu/project-zomboid-server-docker)
(GPL-3.0). **The attribution comments in `scripts/entrypoint.sh` and
`scripts/lib/ini.sh` are a licence obligation — never delete or reword them
away.**

## Layout

```
scripts/            Server container: entrypoint, healthcheck, lib/*.sh
scripts/backup/     Backup sidecar: entrypoint, backup-now, lib/backup.sh
exporter/           Go module for the metrics exporter
tests/unit/*.bats   Unit tests for the shell libraries
tests/*.sh          Integration tests (see "Testing")
docs/               Configuration reference, runbook, backup/restore
grafana/            Dashboard JSON
```

## Non-negotiables

These are decisions the project has already made. Changing one is a design
discussion, not a refactor.

1. **RCON port 27015 is never published to the host.** Publishing it hands out
   remote server administration. It stays reachable only over the Compose
   network.
2. **`ADMIN_PASSWORD` is passed on the first boot only.** Project Zomboid writes
   its whole command line into the log in clear text on every start. See
   `scripts/lib/args.sh`.
3. **INI patching replaces keys in place.** Comments, ordering and unknown keys
   survive untouched, and the file's inode is kept (`cat tmp > file`, never
   `mv`), because it may be bind-mounted. See `scripts/lib/ini.sh`.
4. **Every `FROM` is pinned by digest.** Tags alone are not a pin.
5. **Third-party Go binaries are built from source in a builder stage**, not
   downloaded as release tarballs. A 2023 tarball carries the Go standard
   library of 2023, and no base-image update fixes that. See the comment at the
   top of `Dockerfile`.
6. **The exporter only reads.** Read-only volume mounts, RCON queries. It must
   never gain a way to change the server or the backups.
7. **Container CPU/memory/uptime are deliberately not exported.** cAdvisor
   already produces those; a second source for the same number is a source of
   disagreement.
8. **Linter versions in `.pre-commit-config.yaml` and the `env:` block of
   `.github/workflows/lint.yml` must stay identical.** A linter that reports
   differently locally than in CI turns every finding into an argument about
   which run to believe. Change both or neither.
9. **No speculative configuration.** Every environment variable that exists is
   one somebody needed. New ones need a reason beyond "someone might".

## Testing

Everything runs in containers, so no local toolchain is needed beyond Docker.

```bash
./tests/run-unit.sh          # bats, seconds
./tests/compose-network.sh   # outbound connectivity on the Compose network, seconds
./tests/smoke.sh             # image-level end-to-end, ~20-40 min, ~10 GB download
./tests/stack-smoke.sh       # Compose-level end-to-end, same cost
```

Run `run-unit.sh` and `compose-network.sh` for any change. The two smoke tests
download the real game; run them when touching the entrypoint, the Dockerfiles
or the Compose file, and let CI cover them otherwise.

Go tests, through the same pinned toolchain CI and the release build use:

```bash
docker run --rm -v "${PWD}/exporter:/src" -w /src \
  golang:1.27-trixie@sha256:9baa6b4187bbb98d240372a8a235ac0bb6b5ddd52bba1431dc2f7c0705862728 \
  go test ./...
```

Test the shell libraries as **behaviour**: that a patched INI keeps its
comments, that rotation removes the oldest and nothing else. Not that a
particular `sed` ran.

## Linting

`prek install` once, then `prek run` before committing. The full CI set:

```bash
find scripts tests -name '*.sh' -print0 \
  | xargs -0 docker run --rm -v "${PWD}:/mnt" koalaman/shellcheck:v0.11.0
find scripts tests -name '*.sh' -print0 \
  | xargs -0 docker run --rm -v "${PWD}:/mnt" -w /mnt mvdan/shfmt:v3.14.0-alpine -i 2 -d
docker run --rm -i hadolint/hadolint:v2.15.1 hadolint - < Dockerfile
yamllint -c .yamllint .
zizmor --persona=regular .github/workflows/
```

Zero warnings. If one genuinely cannot be fixed, add an inline ignore with a
comment saying why — see the `hadolint ignore=DL3008` lines for the shape.

## Conventions

**Shell.** `set -euo pipefail` at the top of every executable script (the
healthcheck omits `-e` on purpose, and says so). Two-space indent, `shfmt -i 2`.
Library files under `lib/` are sourced, not executed, and define functions only.
Build command lines as arrays so values with spaces survive.

**Comments explain why, not what.** This codebase is dense with rationale
comments — every one of them records a decision or a failure that already
happened. Match that density. When you remove the code a comment explains,
remove the comment; when you change the decision, change the comment.

**Errors.** Fail fast with a message that says what to do next, including the
concrete command where there is one (`chown -R 1000:1000 <host directory>`).
Distinguish "nothing to do yet" from "broken" — the backup path uses exit code 2
for the former precisely so a fresh install does not open with an error.

**Go.** Standard library plus `prometheus/client_golang` and `gorcon/rcon`.
`gofmt` and `go vet` clean. Interfaces are defined where they are consumed
(`collector.PlayerSource` and friends), which is what makes the collector
testable without a server.

**Documentation belongs in the same change.** README, `docs/`, `CHANGELOG.md`.
Do not leave docs as a follow-up.

## Commits and branches

Conventional Commits, imperative mood, ≤72-character subject, one logical change
per commit. Never push directly to `main`; use a branch and a pull request.
Never commit `.env` or any real credential — the test scripts use obviously fake
values on purpose (`network-check-not-a-real-password`).

If the work was AI-assisted, follow [AI-POLICY.md](AI-POLICY.md).

## Things that will bite you

- **`docker compose up -d` runs the published image, not your code.** The
  services carry both `image:` and `build:`, and Compose's default pull policy
  prefers the published one. Use `--build`. A backup-sidecar change once passed
  review while its container ran month-old code.
- **`container_name` is pinned**, so a stack already running on the host
  collides with the smoke tests. Stop it first.
- **The Compose network must not be `internal: true`.** SteamCMD needs a route
  out or the server cannot install itself. `tests/compose-network.sh` exists
  because this was once broken and nothing else caught it.
- **`PZ_BRANCH=public` is not a beta.** Passing `-beta public` to SteamCMD makes
  it look for a beta that does not exist, and the update then silently does
  nothing.
- **Single-file bind mounts hang on the inode.** This is why `ini_set` copies
  content instead of renaming a temp file into place.
- **A Build 41 world cannot be loaded by Build 42**, or the other way round.
