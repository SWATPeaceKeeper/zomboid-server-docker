# Project Zomboid Dedicated Server

[![Lint](https://github.com/SWATPeaceKeeper/zomboid-server-docker/actions/workflows/lint.yml/badge.svg)](https://github.com/SWATPeaceKeeper/zomboid-server-docker/actions/workflows/lint.yml)
[![Test](https://github.com/SWATPeaceKeeper/zomboid-server-docker/actions/workflows/test.yml/badge.svg)](https://github.com/SWATPeaceKeeper/zomboid-server-docker/actions/workflows/test.yml)
[![Release](https://github.com/SWATPeaceKeeper/zomboid-server-docker/actions/workflows/release.yml/badge.svg)](https://github.com/SWATPeaceKeeper/zomboid-server-docker/actions/workflows/release.yml)
[![Licence: GPL-3.0-or-later](https://img.shields.io/badge/licence-GPL--3.0--or--later-blue.svg)](LICENSE)

Run a [Project Zomboid](https://projectzomboid.com/) dedicated server in Docker,
with scheduled backups and a shutdown that does not eat your world.

Three things set this apart from the other images:

- **The game is not baked into the image.** It installs into a volume on first
  start, so you can switch between Build 42 and Build 41 by changing one
  environment variable, and updating the game never means pulling a new image.
- **Shutdown saves the world.** `docker stop` makes the entrypoint send `quit` to
  the server console and wait for the save to finish. Letting Docker kill the JVM
  instead is how Project Zomboid worlds get corrupted.
- **CI starts a real server.** Every change and every night, a server is
  installed, booted, saved over RCON and stopped, and the published image is
  pulled back and booted again. A red `Test` badge means the game broke the
  image — before your next deploy finds out.

## Contents

- [Requirements](#requirements)
- [Getting started](#getting-started)
- [What the first start does](#what-the-first-start-does)
- [Letting people in](#letting-people-in)
- [Becoming admin](#becoming-admin)
- [Running it day to day](#running-it-day-to-day)
- [Configuration](#configuration)
- [Choosing a game version](#choosing-a-game-version)
- [Mods](#mods)
- [Memory](#memory)
- [Backups](#backups)
- [Troubleshooting](#troubleshooting)
- [Images and versioning](#images-and-versioning)

## Requirements

| | |
|---|---|
| **Docker** | Engine 20.10+ with the Compose v2 plugin (`docker compose`, not `docker-compose`) |
| **Disk** | ~10 GB for Build 42: the install is about 7 GB, plus the world and backups |
| **RAM** | 8 GB host minimum for Build 42, 6 GB for Build 41. See [Memory](#memory) |
| **Ports** | `16261/udp` and `16262/udp` reachable, if people are joining from outside your network |
| **Platform** | linux/amd64. The Project Zomboid server has no arm64 build, so this does not run on a Raspberry Pi or Apple Silicon without emulation |

You do **not** need to own Project Zomboid to run the server: it is a separate
free Steam application and installs anonymously. Everyone who joins needs the
game, of course.

## Getting started

### Option A — just run it

You do not need this repository. Create a directory, put this
`docker-compose.yml` in it, and you are done:

```yaml
name: zomboid

services:
  pz-server:
    image: ghcr.io/swatpeacekeeper/zomboid-server-docker:1
    container_name: pz-server
    restart: unless-stopped
    stop_grace_period: 180s
    environment:
      SERVER_NAME: "myserver"
      PUBLIC_NAME: "Our Apocalypse"
      MAX_PLAYERS: "8"
      PZ_MAX_RAM: "6g"
      ADMIN_PASSWORD: "${PZ_ADMIN_PASSWORD:?set PZ_ADMIN_PASSWORD in .env}"
      RCON_PASSWORD: "${PZ_RCON_PASSWORD:?set PZ_RCON_PASSWORD in .env}"
      SERVER_PASSWORD: "${PZ_SERVER_PASSWORD:-}"
      TZ: "Europe/Berlin"
    ports:
      - "16261:16261/udp"
      - "16262:16262/udp"
    volumes:
      - pz-server:/data/server
      - pz-zomboid:/data/zomboid
    networks: [pz]
    security_opt: [no-new-privileges:true]

  pz-backup:
    image: ghcr.io/swatpeacekeeper/zomboid-server-docker-backup:1
    container_name: pz-backup
    restart: unless-stopped
    depends_on: [pz-server]
    environment:
      RCON_HOST: "pz-server"
      RCON_PASSWORD: "${PZ_RCON_PASSWORD:?set PZ_RCON_PASSWORD in .env}"
      BACKUP_INTERVAL: "6h"
      BACKUP_KEEP: "14"
      TZ: "Europe/Berlin"
    volumes:
      - pz-zomboid:/data/zomboid:ro
      - pz-backups:/data/backups
    networks: [pz]
    security_opt: [no-new-privileges:true]

volumes:
  pz-server:
  pz-zomboid:
  pz-backups:

networks:
  pz:
```

Next to it, create a file called `.env`:

```bash
PZ_ADMIN_PASSWORD=pick-something-long-and-not-reused
PZ_RCON_PASSWORD=a-different-long-one
# Optional: a password players need in order to join at all
PZ_SERVER_PASSWORD=
```

Then start it:

```bash
docker compose up -d
docker compose logs -f pz-server
```

Both passwords are mandatory. Compose refuses to start without them, rather than
quietly bringing up a server that anyone who finds it can administer.

### Option B — clone the repository

Do this if you want to build the image yourself, change the scripts, or keep the
whole thing under version control:

```bash
git clone https://github.com/SWATPeaceKeeper/zomboid-server-docker.git
cd zomboid-server-docker

cat > .env <<'EOF'
PZ_ADMIN_PASSWORD=pick-something-long-and-not-reused
PZ_RCON_PASSWORD=a-different-long-one
EOF

docker compose up -d
docker compose logs -f pz-server
```

**If you intend to change anything, always use `docker compose up -d --build`.**

The bundled `docker-compose.yml` carries both an `image:` and a `build:` section.
Compose's default pull policy prefers the published image over your local source,
so a plain `docker compose up -d` runs the last release and quietly ignores every
edit you made. `--build` is what makes it build what you actually have.

## What the first start does

The first start is slow and mostly silent. It is worth knowing what to expect so
you do not kill it halfway through.

**1. SteamCMD installs the server** — roughly 7 GB on Build 42, a few minutes on
a decent connection:

```
[pz] INFO: No installation found in /data/server, installing now.
[pz] INFO: The first start downloads roughly 7 GB on Build 42 and then
           generates the world, which together takes 10-20 minutes.
 Update state (0x61) downloading, progress: 42.01 (3029756106 / 7212532083)
```

If Steam has a bad day, you will see `SteamCMD attempt 1 failed` and it will try
again. Three attempts, then the container gives up and says so.

**2. The world is generated.** This is the long, quiet part. The log fills with
`LOADING ASSETS`, JVM messages and occasional stack traces from the map loader.
Those are normal and come from the game itself.

```
LOG  : General     > Router detection/configuration starting.
LOG  : General     > If the server hangs here, set UPnP=false.
LOG  : General     > LOADING ASSETS: START
```

The UPnP line is worth remembering — see [Troubleshooting](#troubleshooting).

**3. The server is ready.** The reliable signal is not a log line, it is the
container's health status, which only turns healthy once the server answers RCON:

```bash
docker compose ps
# NAME        STATUS
# pz-server   Up 12 minutes (healthy)
```

Watch it turn over with:

```bash
until [ "$(docker inspect -f '{{.State.Health.Status}}' pz-server)" = healthy ]; do
  sleep 10; echo "still starting..."
done; echo "ready"
```

Meanwhile the backup sidecar reports that there is nothing to save yet. That is
expected on a fresh install and not an error:

```
[pz] INFO: Startup backup skipped: the server has no world yet
```

## Letting people in

### On your own network

Give people the Docker host's LAN address and the port. In Project Zomboid:
**Join → Favorites → Add server**, then enter `192.168.1.50` and `16261`. The
server password, if you set one, goes in the same dialog.

### Over the internet

Forward **UDP 16261 and UDP 16262** on your router to the Docker host. Nothing
else. Project Zomboid speaks its own UDP protocol, so a reverse proxy such as
Traefik or nginx does not apply here — there is no HTTP to proxy.

Then give people your public address and port `16261`.

To have the server appear in the in-game public browser instead:

```yaml
environment:
  PUBLIC: "true"
  PUBLIC_NAME: "Our Apocalypse"
```

Leave `PUBLIC` at `false` and hand out the address directly if you would rather
not be found by strangers.

**Do not forward port 27015.** That is RCON, which is full remote administration
of your server. This stack keeps it on the internal Docker network on purpose.

## Becoming admin

The `ADMIN_PASSWORD` you set creates an in-game account called `admin` on the
very first boot. Join the server, log in with that name and password, and you get
the admin panel and console commands.

The password is passed to the server **only on that first boot**. Project Zomboid
writes its whole command line into the log in clear text on every start, so
passing it every time would copy your password into every log file for no
benefit. After the first boot it lives in the world database.

To change it later, use `/changepwd` in-game — changing the environment variable
afterwards has no effect on an existing world.

## Running it day to day

```bash
docker compose ps                       # what is running, and is it healthy
docker compose logs -f pz-server        # follow the server log
docker compose logs -f pz-backup        # follow backup activity
docker compose restart pz-server        # saves the world first, then restarts
docker compose stop                     # clean shutdown, world saved
docker compose up -d                    # start again
```

`docker compose stop` and `restart` are safe: the container gets 180 seconds to
send `quit` and let the server write everything out. You will see it happen:

```
[pz] INFO: Shutdown requested, sending 'quit' to the server console
[pz] INFO: Server stopped cleanly with exit code 0
```

### Updating the game

With the default `UPDATE_ON_START=true`, SteamCMD runs on every start, so an
update is just a restart:

```bash
docker compose restart pz-server
```

Take a backup first if you run mods — a game update can break them:

```bash
docker compose exec pz-backup backup-now
```

### Talking to the running server

RCON is available inside the containers:

```bash
docker compose exec pz-server rcon -a 127.0.0.1:27015 -p "$PZ_RCON_PASSWORD" players
docker compose exec pz-server rcon -a 127.0.0.1:27015 -p "$PZ_RCON_PASSWORD" save
```

`players` and `save` are the two you will use most; the healthcheck and the
backup sidecar rely on them. Everything else comes from Project Zomboid's own
console, not from this image, so the available commands depend on your build —
ask the server itself:

```bash
docker compose exec pz-server rcon -a 127.0.0.1:27015 -p "$PZ_RCON_PASSWORD" help
```

A civilised restart, announced first (`servermsg` is a stock Project Zomboid
command; check `help` if your build disagrees):

```bash
PW="$PZ_RCON_PASSWORD"
docker compose exec pz-server rcon -a 127.0.0.1:27015 -p "$PW" \
  'servermsg "Server restarts in 5 minutes"'
sleep 300
docker compose restart pz-server
```

## Configuration

Configuration is split deliberately:

- **The environment owns operational values** — passwords, ports, player limit,
  server name, mods, heap size. These are patched into the server's INI on every
  start, so the Compose file stays the single source of truth for them.
- **The INI owns everything else.** Every other key in `<SERVER_NAME>.ini`, and
  all of `<SERVER_NAME>_SandboxVars.lua`, is yours. Comments, ordering and
  settings this image has never heard of all survive untouched — which matters,
  because Project Zomboid adds INI keys between builds.

Concretely, on a stock Build 42 server the INI is 420 lines with 134 comment
lines. After a start, the nine managed keys have been replaced **where they
already were** — `DefaultPort` on line 58, `RCONPassword` on line 167,
`WorkshopItems` on line 210 — and every comment is still there. Nothing is
appended, reordered or dropped.

Full variable reference: [`docs/configuration.md`](docs/configuration.md).

### Editing the sandbox settings

Zombie population, loot rarity, day length and everything else in that class live
in `<SERVER_NAME>_SandboxVars.lua`, inside the `pz-zomboid` volume. The server
reads it at start, so it has to be stopped:

```bash
docker compose stop pz-server

docker run --rm -it \
  -v zomboid-server-docker_pz-zomboid:/data/zomboid \
  -w /data/zomboid/Server \
  alpine sh -c 'apk add --no-cache nano >/dev/null && nano myserver_SandboxVars.lua'

docker compose start pz-server
```

Replace `myserver` with your `SERVER_NAME`, and the volume prefix with your
Compose project name if you changed it. `docker volume ls` shows the real names.

The same applies to `<SERVER_NAME>.ini` for the settings not managed through the
environment.

### Running more than one server

The Compose file sets `container_name`, which is convenient but global. To run a
second, independent server on the same host, give it its own project name and
override the container names:

```yaml
# second-server/docker-compose.override.yml
services:
  pz-server:
    container_name: pz-server-two
    ports:
      - "16271:16261/udp"
      - "16272:16262/udp"
  pz-backup:
    container_name: pz-backup-two
```

```bash
docker compose -p zomboid-two up -d
```

## Choosing a game version

```yaml
environment:
  PZ_BRANCH: "public"     # Build 42, the current stable branch (default)
  PZ_BRANCH: "legacy41"   # Build 41
```

Recreate the container and SteamCMD switches the installation in the volume. No
rebuild, no new image.

**A Build 41 save cannot be loaded by Build 42, or the other way round.** If you
want to keep both, give each branch its own set of volumes rather than switching
back and forth on one world.

## Mods

Two settings, and they are not interchangeable:

```ini
WorkshopItems=2392709985;2882031973    # numeric Steam Workshop IDs: what to download
Mods=\ModIdOne;\ModIdTwo               # internal mod ids: what to load
```

- `WorkshopItems` takes the numeric id from the Workshop URL. The server
  downloads these itself on start; there is no separate download step.
- `Mods` takes the `id=` value from each mod's `mod.info` — not the Workshop
  title, not the folder name. One Workshop item can contain several mods, and
  then all of their ids belong here.
- **On Build 42, every entry in `Mods` needs a leading backslash** (`\ModId`).
  Build 41 does not. A missing backslash is the single most common reason mods
  download successfully and then quietly do not load.

Set them through the environment:

```yaml
environment:
  WORKSHOP_IDS: "2392709985;2882031973"
  MOD_IDS: "\\ModIdOne;\\ModIdTwo"
```

The container warns in the log when it sees a Build 42 mod id without a
backslash, and deliberately does not correct it — silently rewriting your
configuration would be worse than a warning you can act on.

If you would rather manage the mod lines by hand in the INI, set
`SELF_MANAGED_MODS=true` and the container will leave both alone.

Mods update when the server restarts, because that is when it re-checks the
Workshop. That is also the most common way a working server suddenly breaks, so
back up before a restart if your list is long.

## Memory

The default `PZ_MAX_RAM` is `4g`. That is a conservative default, not a
recommendation:

| Setup | Suggested heap | Host RAM needed |
|---|---|---|
| Build 41, up to 8 players | 3–4 GB | 6–7 GB |
| Build 42, 2–3 players | 4–6 GB | 8–9 GB |
| Build 42, real group with mods | 6–8 GB | 10–12 GB |

Build 42 streams the map using memory **outside** the Java heap, so the host
needs roughly 3 GB of headroom on top of whatever you set. A heap larger than the
machine can actually supply shows up as a container that restarts before it ever
becomes healthy.

The value is written into `ProjectZomboid64.json` and nowhere else, so there is
only ever one number to look at.

## Backups

The sidecar takes a backup when it starts, then every `BACKUP_INTERVAL` (6 hours
by default), keeping `BACKUP_KEEP` generations (14). It asks the server to save
over RCON first, so the archive is consistent.

```bash
docker compose exec pz-backup backup-now      # take one right now
docker run --rm -v zomboid-server-docker_pz-backups:/b alpine ls -lh /b
```

`BACKUP_MODE=tar` (default) writes self-contained `.tar.zst` archives.
`BACKUP_MODE=dir` writes a plain directory copy instead, which deduplicating
tools such as Borg and restic handle far better — use that one if borgmatic or
similar already covers the directory.

**Read [`docs/backup-restore.md`](docs/backup-restore.md) and try the restore
once before you need it.** A restore procedure nobody has run is a guess.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Container restarts before ever becoming healthy | Heap bigger than the host can supply | Lower `PZ_MAX_RAM`; check `free -g` |
| `... is not writable by uid 1000` | Bind mount owned by someone else | `sudo chown -R 1000:1000 <host directory>` |
| Mods download but never load | Missing backslash in `Mods` on Build 42, or a Workshop title used as a mod id | Use the `id=` from `mod.info`, prefix each with `\` |
| Friends cannot connect from outside | UDP ports not forwarded | Forward `16261/udp` and `16262/udp`; do not forward 27015 |
| Hangs at `Router detection/configuration starting` | UPnP probing, useless in a container | Set `UPnP=false` in `<SERVER_NAME>.ini`, restart |
| World reverted after a crash | Container was killed instead of stopped | Check `stop_grace_period` is 180s; restore a backup |
| `Steamcmd needs to be online to update` | The container has no route out | Check the network is not `internal: true`, and that the host has DNS |
| Never turns healthy, but the log says it started | `RCON_PASSWORD` differs from `RCONPassword` in the INI | Make them match and restart |

More, with commands: [`docs/runbook.md`](docs/runbook.md).

## Images and versioning

| Image | Contents |
|---|---|
| `ghcr.io/swatpeacekeeper/zomboid-server-docker` | The server |
| `ghcr.io/swatpeacekeeper/zomboid-server-docker-backup` | The backup sidecar |

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
- **Minor** — new variables or features; existing setups keep working untouched.
- **Patch** — fixes only.

A version tag records what this wrapper does; it does not freeze the Project
Zomboid version. With `UPDATE_ON_START=true` the game updates itself from Steam
regardless. To pin a running instance completely, keep both the image digest and
the volume.

See [CHANGELOG.md](CHANGELOG.md) for what changed between versions.

### How this is tested

- **Unit tests** (`bats`) cover the shell libraries as behaviour: INI patching
  keeps comments and unrelated keys, mod-list validation, branch selection,
  argument construction, backup rotation.
- **A Compose network check** proves a container on the stack's network can reach
  the internet, because an unreachable Steam is a silent, total failure.
- **An end-to-end smoke test** installs a real server, waits for healthy, saves
  over RCON, stops it and asserts a clean exit with a written world.
- **The release pipeline pulls back the image it just pushed** and runs that same
  smoke test against it, so the artefact you download is the one proven to boot.
- **It all runs nightly**, so a Project Zomboid update that breaks the image
  shows up on the badge instead of in your deployment.

## Credits

The graceful-shutdown mechanism and the in-place INI patching approach are
adapted from
[Danixu/project-zomboid-server-docker](https://github.com/Danixu/project-zomboid-server-docker)
(GPL-3.0), with attribution in the file headers. That project solved both
problems well and there was no sense in solving them again differently.

## Licence

GPL-3.0-or-later. See [LICENSE](LICENSE).

Not affiliated with The Indie Stone or Valve. This project ships no game files;
Project Zomboid and SteamCMD remain subject to their own terms.
