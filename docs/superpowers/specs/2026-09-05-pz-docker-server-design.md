# Project Zomboid Dedicated Server — Container Image Design

- **Date:** 2026-09-05
- **Status:** Approved
- **Repository:** `github.com/SWATPeaceKeeper/pz-docker-server`
- **License:** GPL-3.0-or-later

## 1. Purpose

Provide a container image and Compose stack that runs a Project Zomboid dedicated
server with as little manual work as possible: switch game branch by environment
variable, patch the operational settings from the environment, back the world up
on a schedule, and prove on every change that the server still starts and shuts
down without corrupting the save.

The image is published publicly, so it must be useful outside the author's
homelab and must not redistribute Steam content.

## 2. Background

Project Zomboid ships a free Linux-native dedicated server as Steam app `380870`,
installable anonymously through SteamCMD. Two facts drive the whole design:

1. **Configuration does not live in the install directory.** The server writes
   `Server/<name>.ini`, `Server/<name>_SandboxVars.lua`,
   `Server/<name>_spawnregions.lua`, `Saves/` and `Logs/` into a separate data
   directory (`~/Zomboid` by default, overridable with `-cachedir=`). Install
   directory and data directory therefore need separate volumes.
2. **Killing the process corrupts worlds.** The server only writes the world out
   on its `quit` console command. A container that lets Docker `SIGKILL` the JVM
   after the default 10 s grace period will eventually destroy a save.

### Evaluation of existing images

`Danixu/project-zomboid-server-docker` (370 stars, actively maintained, GPL-3.0)
is the only live candidate; `Renegade-Master/zomboid-dedicated-server` has not
been touched since June 2024 and carries 32 open issues, `jsknnr` is archived.

Danixu solves two problems well, and this project reuses both with attribution:

- **Graceful shutdown** (`scripts/entry.sh:325-377`): the server's stdin is a
  FIFO held open by the entrypoint; a `SIGTERM` handler writes `quit` into it and
  blocks until the JVM exits, with a guard so a second signal cannot abandon a
  save in progress.
- **`set_ini_option()`** (`scripts/entry.sh:178-188`): replaces an existing INI
  key in place, appends it when missing — preserving comments and ordering.

It does not meet the requirements here, for reasons that are architectural rather
than incidental:

| Requirement | Danixu | Why it cannot simply be added |
|---|---|---|
| Branch selectable at runtime | No | `STEAMAPPBRANCH` is a **build ARG**; server files are baked into the image. The `FORCEUPDATE` path writes into the container's writable layer, so the download is discarded whenever the container is recreated. |
| Tested in CI | No | The workflow builds and pushes on a schedule and never starts the server. No linting, no vulnerability scan. |
| Healthcheck | No | Absent entirely. |
| Backups | No | Absent entirely. |
| Rootless | Partial | Entrypoint runs as root and does `chown -R` over the whole world directory on every start; only the server process is dropped to `steam`. |
| RCON not exposed | No | `docker-compose.yml` publishes `27015:27015/tcp`. |

Additionally, baking the Steam files into a published image redistributes
Valve/The Indie Stone content. Downloading into a volume at first start avoids
this and is what this design does.

## 3. Architecture

```
┌─────────────────┐   RCON, internal network only   ┌──────────────────┐
│  pz-server      │◄────────────────────────────────│  pz-backup       │
│  (game server)  │                                 │  (sidecar)       │
└────────┬────────┘                                 └────────┬─────────┘
         │ 16261/udp, 16262/udp  ── published                │
         │                                                   │
    ┌────▼──────────┬───────────────────┐            ┌───────▼─────────┐
    │ vol: server   │ vol: zomboid      │◄───────────│ vol: backups    │
    │ Steam install │ config/saves/logs │   reads    │ archives        │
    └───────────────┴───────────────────┘            └─────────────────┘
```

### Volumes

| Volume | Container path | Contents |
|---|---|---|
| `pz-server` | `/data/server` | SteamCMD install of app `380870`, incl. `steamapps/workshop/content/108600` |
| `pz-zomboid` | `/data/zomboid` | `Server/`, `Saves/`, `Logs/`, `db/` — passed as `-cachedir=` |
| `pz-backups` | `/data/backups` | Rotated world archives |

### Networks

Two networks. `pz-internal` carries RCON between the server and the sidecar and
is not published. Only `16261/udp` and `16262/udp` are exposed to the host.
Project Zomboid speaks its own UDP protocol, so a reverse proxy is not
applicable; public reachability is a UDP port forward on the router.

## 4. Image

Base: `steamcmd/steamcmd:ubuntu-24`, pinned by digest. Two stages — the first
fetches `gorcon/rcon-cli` v0.10.3 and verifies its checksum, the second is the
runtime image.

> **Corrected after implementation.** This section originally estimated ~170 MB,
> read off Docker Hub's *compressed* figure for the base image. The base is 496 MB
> uncompressed and the finished image is 519 MB — this project adds 23 MB. The
> point of the design is unaffected: the ~7 GB of game files stay out of the image.

The image contains SteamCMD, `rcon-cli` and the scripts. It does **not** contain
Project Zomboid server files.

Runs as UID/GID `1000` throughout; there is no root phase at runtime and no
recursive `chown` at start, which matters once a world grows large. Bind mounts
must be owned by `1000:1000`; the README documents this.

## 5. Server container lifecycle

Scripts are split by responsibility so each part can be unit-tested and stays
within the project's function-size limits.

| File | Responsibility |
|---|---|
| `scripts/entrypoint.sh` | Orchestration, signal handling, process supervision |
| `scripts/lib/steam.sh` | Install/update via SteamCMD, branch selection |
| `scripts/lib/ini.sh` | Read and patch INI keys, normalise mod lists |
| `scripts/lib/args.sh` | Build JVM and server arguments from the environment |
| `scripts/healthcheck.sh` | Readiness probe |

Startup sequence:

1. Verify `/data/server` and `/data/zomboid` are writable; fail fast with an
   actionable message if not.
2. Install the app if missing. Update it when `UPDATE_ON_START=true`.
   `PZ_BRANCH=public` runs `app_update 380870 validate`;
   any other value runs `app_update 380870 -beta <branch> validate`. Passing
   `-beta public` makes SteamCMD look for a non-existent beta and silently skip
   the update, so the `public` case must not pass `-beta`.
3. Patch the INI (section 6).
4. Write `-Xms`/`-Xmx` into `ProjectZomboid64.json` from `PZ_MAX_RAM`.
5. Create the console FIFO, start the server with stdin attached to it.
6. On `SIGTERM`/`SIGINT`, write `quit` into the FIFO and wait for the JVM to
   exit. A second signal must not interrupt an in-progress save.

`stop_grace_period: 180s` in Compose, because saving a large world routinely
exceeds Docker's 10 s default.

## 6. Configuration model

Hybrid: the environment owns operational values, the INI file owns everything
else.

**Patched from the environment on every start:** `SERVER_NAME`,
`SERVER_PASSWORD`, `ADMIN_USERNAME`, `ADMIN_PASSWORD`, `RCON_PASSWORD`,
`PUBLIC`, `PUBLIC_NAME`, `MAX_PLAYERS`, `GAME_PORT`, `UDP_PORT`, `RCON_PORT`,
`MOD_IDS`, `WORKSHOP_IDS`.

**Never touched:** every other key in `<name>.ini`, the whole of
`<name>_SandboxVars.lua`, and `<name>_spawnregions.lua`. Comments, ordering and
unknown keys survive. Setting `SELF_MANAGED_MODS=true` additionally excludes the
two mod lines.

The INI is created empty before first boot if absent, so that values set here
apply on the very first run instead of requiring a restart.

### Workshop mods

The server downloads Workshop items itself at startup from the `WorkshopItems=`
list, provided Steam integration is active (`-nosteam` not set). No separate
SteamCMD download step is required; the workshop content lands under the install
directory and is therefore already persistent.

`WorkshopItems=` takes numeric Workshop IDs; `Mods=` takes internal mod IDs from
each mod's `mod.info`. In Build 42 each entry in `Mods=` requires a leading
backslash (`\ModID`); Build 41 does not. When `PZ_BRANCH` targets Build 42 and
`MOD_IDS` entries lack the backslash, the entrypoint **logs a warning and changes
nothing**. Silently rewriting user configuration is not acceptable — it produces
behaviour that cannot be reasoned about later.

## 7. Backup sidecar

A separate container sharing the volumes and the internal network.

Triggers:

- **Scheduled** every `BACKUP_INTERVAL` (default `6h`): issue `save` over RCON,
  wait for it to complete, create the archive, then rotate to `BACKUP_KEEP`
  generations (default `14`).
- **On start**, when `BACKUP_ON_START=true` (default): captures the state before
  the freshly started server writes to it — effectively the state of the last
  clean shutdown. This is deliberately preferred over trying to signal a backup
  across container boundaries during shutdown, which is racy.
- **Manual**: `docker compose exec pz-backup backup-now`.

Modes:

- `BACKUP_MODE=tar` (default) — self-contained `.tar.zst` archives.
- `BACKUP_MODE=dir` — rotating uncompressed copy. Deduplicating backup tools such
  as Borg/borgmatic handle this far better than compressed tarballs; use it when
  a host-level backup already covers the directory.

A failed backup exits non-zero and logs the failure. If `NTFY_URL` is set, it
also sends a notification; when unset, nothing external is contacted.

## 8. Health and security

The healthcheck queries `players` over RCON — the only signal that actually means
"accepting players" rather than "the JVM is alive". Without `RCON_PASSWORD` it
degrades to a process and listening-socket check.

RCON is **not published to the host**. The server and the sidecar reach it over
`pz-internal`. Exposing RCON publicly, as some existing images do by default,
hands out remote server administration.

Passwords are supplied through the environment (`${PZ_ADMIN_PASSWORD:?}` style
required-variable syntax in Compose) and never committed.

## 9. Continuous integration

Actions pinned to commit SHAs with version comments, `persist-credentials:
false`, workflows scanned with zizmor.

| Workflow | Trigger | Contents |
|---|---|---|
| `lint.yml` | push, PR | hadolint, shellcheck, `shfmt -d -i 2`, yamllint, zizmor |
| `test.yml` | PR, nightly | `bats` unit tests, then image smoke test |
| `release.yml` | main, tags | Trivy scan, push to `ghcr.io/swatpeacekeeper/pz-docker-server` |

Unit tests (`bats`) cover the pure-bash logic as behaviour: INI patching
preserves comments and unrelated keys, appends missing keys, and handles values
containing `&`, `|` and `\`; mod-list normalisation; branch argument selection
(`public` must not produce `-beta`); argument construction with values containing
spaces.

The smoke test is the part missing from every comparable image: build the image,
start a container against a scratch volume, wait for the healthcheck to report
healthy, issue `save` over RCON, `docker stop` it, then assert the exit was clean
and `Saves/` contains data. Timeout 20 minutes, because a first boot downloads
roughly 7 GB on Build 42 and generates a world. Steam downloads are flaky, so
the install step retries.

The nightly run exists to catch a Project Zomboid update breaking the image
before a deployment does.

`renovate.json` uses `config:best-practices` with `minimumReleaseAge: "7 days"`
and grouped updates.

## 10. Defaults

| Variable | Default | Note |
|---|---|---|
| `PZ_BRANCH` | `public` | Build 42, the current stable branch. `legacy41` for Build 41. |
| `PZ_MAX_RAM` | `4g` | Deliberately conservative. Build 42 with more than two or three players wants 6–8 GB; the README says so explicitly. |
| `UPDATE_ON_START` | `true` | |
| `BACKUP_INTERVAL` | `6h` | |
| `BACKUP_KEEP` | `14` | |
| `BACKUP_MODE` | `tar` | |
| `BACKUP_ON_START` | `true` | |

## 11. Repository layout

```
Dockerfile
Dockerfile.backup
docker-compose.yml
renovate.json
LICENSE                        GPL-3.0
README.md
docs/
  configuration.md             every environment variable
  backup-restore.md            including the borgmatic path
  runbook.md                   update, branch switch, troubleshooting
scripts/
  entrypoint.sh
  healthcheck.sh
  lib/{steam.sh,ini.sh,args.sh}
  backup/{entrypoint.sh,backup-now.sh}
tests/
  unit/*.bats
  smoke.sh
.github/workflows/{lint.yml,test.yml,release.yml}
```

Documentation is written in English because the repository is public.

## 12. Out of scope

Deferred to a later, separately scoped iteration:

- Prometheus exporter and Grafana dashboard (player count, heap, uptime). No
  ready-made Project Zomboid exporter exists; this needs a purpose-built RCON
  sidecar and is worth doing once real usage shows which numbers matter.

Not planned:

- Web administration UI.
- Running multiple worlds from one container.
- Automatic detection of Workshop mod updates.
- Copying sandbox presets out of the install directory.

## 13. Risks

| Risk | Mitigation |
|---|---|
| First start takes 10–20 minutes and depends on Steam | Documented; healthcheck has a long `start_period`; install retries |
| A Project Zomboid update breaks startup | Nightly CI smoke test |
| Build 42 with the 4 GB default heap is tight | README states the recommendation; the value is a single environment variable |
| Steam download flakiness fails CI | Retry with backoff; nightly runs make a single failure non-blocking |
| Reused GPL-3.0 code obliges this repository | Repository is GPL-3.0-or-later, attribution in the file headers |
