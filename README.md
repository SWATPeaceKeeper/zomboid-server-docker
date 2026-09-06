# Project Zomboid Dedicated Server

[![Lint](https://github.com/SWATPeaceKeeper/zomboid-server-docker/actions/workflows/lint.yml/badge.svg)](https://github.com/SWATPeaceKeeper/zomboid-server-docker/actions/workflows/lint.yml)
[![Test](https://github.com/SWATPeaceKeeper/zomboid-server-docker/actions/workflows/test.yml/badge.svg)](https://github.com/SWATPeaceKeeper/zomboid-server-docker/actions/workflows/test.yml)
[![Release](https://github.com/SWATPeaceKeeper/zomboid-server-docker/actions/workflows/release.yml/badge.svg)](https://github.com/SWATPeaceKeeper/zomboid-server-docker/actions/workflows/release.yml)
[![Licence: GPL-3.0-or-later](https://img.shields.io/badge/licence-GPL--3.0--or--later-blue.svg)](LICENSE)

A container image and Compose stack for running a [Project Zomboid](https://projectzomboid.com/)
dedicated server.

The `Test` badge is the one that matters: it runs nightly and starts a real
server, so it goes red when a Project Zomboid update breaks the image — not when
someone next tries to deploy it.

The Steam server files are **not** baked into the image. They are downloaded into
a volume the first time the container starts, which means the game branch can be
switched at runtime without rebuilding anything, and no Steam content is
redistributed through this image.

The server saves the world on shutdown. `docker stop` sends `SIGTERM`, the
entrypoint answers with the `quit` console command and waits for the save to
finish, instead of letting Docker kill the JVM mid-write.

## Quick start

```bash
git clone https://github.com/SWATPeaceKeeper/zomboid-server-docker.git
cd zomboid-server-docker

export PZ_ADMIN_PASSWORD='choose-something-long'
export PZ_RCON_PASSWORD='choose-something-else-long'

docker compose up -d
docker compose logs -f pz-server
```

> **The first start takes a while.** On Build 42 the server download is roughly
> **7 GB**, and the first boot then generates the world before it accepts anyone.
> Expect 10 to 20 minutes before the container reports `healthy`. Subsequent
> starts take under a minute.

Both passwords are required. Compose refuses to start without them rather than
quietly bringing up a server anyone can administer. Put them in a `.env` file next
to `docker-compose.yml` instead of exporting them, if you prefer.

## Ports

| Port | Protocol | Purpose | Expose to the internet? |
|---|---|---|---|
| 16261 | UDP | Game traffic | Yes |
| 16262 | UDP | Direct connections | Yes |
| 27015 | TCP | RCON | **No** |

Project Zomboid speaks its own UDP protocol, so a reverse proxy does not apply.
To let friends connect from outside, forward **only the two UDP ports** on your
router.

RCON is deliberately not published to the host. The server and the backup sidecar
reach it over an internal Docker network. Exposing it hands out remote server
administration to anyone who guesses the password.

## Memory

The default `PZ_MAX_RAM` is `4g`. That is a conservative default, not a
recommendation:

| Setup | Suggested heap | Host RAM needed |
|---|---|---|
| Build 41, up to 8 players | 3–4 GB | 6–7 GB |
| Build 42, 2–3 players | 4–6 GB | 8–9 GB |
| Build 42, real group with mods | 6–8 GB | 10–12 GB |

Build 42 streams the map using memory **outside** the Java heap, so the host needs
roughly 3 GB of headroom on top of whatever `-Xmx` you set. A heap larger than the
machine can actually supply shows up as a container that restarts before it ever
becomes healthy.

The value is written into `ProjectZomboid64.json` and nowhere else, so there is
only ever one number to look at.

## Choosing a game version

```yaml
environment:
  PZ_BRANCH: "public"     # Build 42, the current stable branch (default)
  PZ_BRANCH: "legacy41"   # Build 41
```

Recreate the container and SteamCMD switches the installation in the volume. No
rebuild, no new image.

Keep separate volumes per branch if you want to keep both worlds. A Build 41 save
is not loadable by Build 42.

## Mods

Two settings, and they are not interchangeable:

```ini
WorkshopItems=2392709985;2882031973    # numeric Steam Workshop IDs, what to download
Mods=\ModIdOne;\ModIdTwo               # internal mod ids, what to load
```

- `WorkshopItems` takes the numeric id from the Workshop URL. The server downloads
  these itself on start; there is no separate download step.
- `Mods` takes the `id=` value from each mod's `mod.info` — not the Workshop title,
  not the folder name. One Workshop item can contain several mods, and then all of
  their ids belong here.
- **On Build 42, every entry in `Mods` needs a leading backslash** (`\ModId`).
  Build 41 does not. A missing backslash is the single most common reason mods
  download successfully and then do not load.

The container warns in the log when it spots a Build 42 mod id without a backslash,
and deliberately does not correct it — silently rewriting your configuration would
be worse than a warning you can act on.

Set them through `MOD_IDS` and `WORKSHOP_IDS`, or set `SELF_MANAGED_MODS=true` and
edit the INI yourself.

## Configuration

A small set of operational keys is patched into `<SERVER_NAME>.ini` on every start.
**Everything else in that file, and all of `<SERVER_NAME>_SandboxVars.lua`, is
yours** — comments, ordering and unknown settings survive untouched.

See [`docs/configuration.md`](docs/configuration.md) for every variable,
[`docs/backup-restore.md`](docs/backup-restore.md) for the backup modes and the
restore procedure, and [`docs/runbook.md`](docs/runbook.md) for updates, branch
switches and troubleshooting.

## Backups

A sidecar container takes a backup on start, then every `BACKUP_INTERVAL`
(default 6 hours), keeping `BACKUP_KEEP` generations (default 14). It asks the
server to save over RCON first.

```bash
docker compose exec pz-backup backup-now     # take one right now
```

`BACKUP_MODE=tar` writes self-contained `.tar.zst` archives. `BACKUP_MODE=dir`
writes a plain directory copy instead, which deduplicating backup tools such as
Borg handle far better. Read the restore procedure before you need it.

## Images and versioning

Two images are published to GHCR:

| Image | Contents |
|---|---|
| `ghcr.io/swatpeacekeeper/zomboid-server-docker` | The server |
| `ghcr.io/swatpeacekeeper/zomboid-server-docker-backup` | The backup sidecar |

Both are tagged the same way:

| Tag | Meaning | Use it when |
|---|---|---|
| `1.4.2` | An exact release | You want a specific version and no surprises |
| `1.4` | Newest patch of that minor | You want fixes but no new behaviour |
| `1` | Newest release of that major | You accept new features, not breaking changes |
| `latest` | Newest release | You want the current version |
| `edge` | Current `main` | You are testing unreleased changes |
| `sha-<commit>` | One exact commit | You need to pin something down precisely |

Versions follow [semantic versioning](https://semver.org/), applied to **this
wrapper**, not to Project Zomboid:

- **Major** — a change that needs action from you: a renamed or removed variable,
  a changed volume layout, a different default that alters behaviour.
- **Minor** — new variables or features, existing setups keep working untouched.
- **Patch** — fixes only.

A release is cut by tagging a commit on `main`:

```bash
git tag -a v1.4.2 -m "Fix the backup rotation off-by-one"
git push origin v1.4.2
```

The release workflow builds both images, scans them with Trivy, pushes every tag
above, and then **pulls the pushed server image back and starts it** — so the
artefact you download is the one that was proven to boot, not a local rebuild of
the same source. `edge` moves on every push to `main`; `latest` moves only when a
version is tagged.

Note that a version tag records what this wrapper does — it does not freeze the
Project Zomboid version. With `UPDATE_ON_START=true` the game updates itself from
Steam regardless. To pin a running instance completely, keep both the image digest
and the volume.

See [CHANGELOG.md](CHANGELOG.md) for what changed between versions.

## Credits

The graceful-shutdown mechanism and the in-place INI patching approach are adapted
from [Danixu/project-zomboid-server-docker](https://github.com/Danixu/project-zomboid-server-docker)
(GPL-3.0), with attribution in the file headers. That project solved both problems
well and there was no sense in solving them again differently.

## Licence

GPL-3.0-or-later. See [LICENSE](LICENSE).

This project is not affiliated with The Indie Stone or Valve. It ships no game
files; Project Zomboid and SteamCMD remain subject to their own terms.
