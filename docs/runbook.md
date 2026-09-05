# Runbook

## Updating the game

With the default `UPDATE_ON_START=true`, SteamCMD runs on every start, so an
update is a restart:

```bash
docker compose restart pz-server
```

The restart is clean: the world is saved before the container stops.

If you prefer controlled maintenance windows, set `UPDATE_ON_START=false` and
update deliberately:

```bash
docker compose stop pz-server
UPDATE_ON_START=true docker compose up -d pz-server
```

A Project Zomboid update can break mods. Take a backup first
(`docker compose exec pz-backup backup-now`) and check the log for mod errors
afterwards.

## Switching the game version

```bash
# Build 41
PZ_BRANCH=legacy41 docker compose up -d pz-server
```

SteamCMD switches the installation inside the volume; no rebuild is needed. Watch
the log — the first switch re-downloads a large part of the installation.

**A Build 42 world cannot be loaded by Build 41 and vice versa.** To keep both,
give each branch its own volumes rather than switching back and forth on one
world.

## Changing the heap

```bash
PZ_MAX_RAM=6g docker compose up -d pz-server
```

The value is written into `ProjectZomboid64.json` at startup. Check what the host
can actually spare first:

```bash
free -g
```

Leave roughly 3 GB beyond the heap for the JVM's non-heap allocations and the
rest of the machine.

## Adding mods

1. Collect the Workshop ids from the URLs, and the internal mod ids from each
   mod's `mod.info` (`id=`).
2. Set both lists, remembering the backslash on Build 42:

   ```yaml
   environment:
     WORKSHOP_IDS: "2392709985;2882031973"
     MOD_IDS: "\\ModIdOne;\\ModIdTwo"
   ```

3. Recreate the container. The server downloads the Workshop items itself on
   start.

   ```bash
   docker compose up -d pz-server
   ```

4. Watch the log for the mods being loaded. If they download but never load,
   re-read step 2 — that is almost always the backslash or a Workshop title used
   where a mod id belongs.

Dependencies are not resolved for you. A mod that requires another needs both, in
dependency order.

## Reading logs

```bash
docker compose logs -f pz-server            # container output
docker compose logs -f pz-backup            # backup activity
```

The server's own log files live in the data volume under `Logs/`, and survive
container recreation:

```bash
docker compose exec pz-server ls -lt /data/zomboid/Logs | head
```

Container output does **not** survive recreation. If you are investigating an
incident, save it before running `docker compose up -d`.

## Administering the running server

RCON is reachable from inside the stack:

```bash
docker compose exec pz-server rcon -a 127.0.0.1:27015 -p "$PZ_RCON_PASSWORD" players
docker compose exec pz-server rcon -a 127.0.0.1:27015 -p "$PZ_RCON_PASSWORD" save
docker compose exec pz-server rcon -a 127.0.0.1:27015 -p "$PZ_RCON_PASSWORD" \
  'servermsg "Restarting in 5 minutes"'
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Container restarts before ever becoming healthy | Heap larger than the host can supply | Lower `PZ_MAX_RAM`, check `free -g` |
| `... is not writable by uid 1000` | Bind mount owned by another user | `sudo chown -R 1000:1000 <host directory>` |
| Mods download but do not load | Missing backslash in `Mods` on Build 42, or a Workshop title used instead of a mod id | Use the `id=` from `mod.info`, prefix each with `\` |
| Players cannot connect from outside | UDP ports not forwarded | Forward `16261/udp` and `16262/udp` on the router |
| World reverted after a crash | Container was killed rather than stopped | Check `stop_grace_period` is 180s, restore from a backup |
| Server hangs at "Router detection/configuration starting" | UPnP probing, useless in a container | Set `UPnP=false` in `<SERVER_NAME>.ini` and restart |
| Healthcheck never turns healthy but the log says the server started | `RCON_PASSWORD` mismatch between INI and environment | Make them match, or clear `RCONPassword` in the INI and restart |
| First start seems stuck | Normal: roughly 7 GB download plus world generation | Give it 10–20 minutes; watch `docker compose logs -f pz-server` |

## Health and readiness

The healthcheck asks the server over RCON for its player list, which is the only
signal that actually means "accepting players". A JVM that is alive but still
generating the world is correctly reported as not yet healthy.

```bash
docker inspect -f '{{.State.Health.Status}}' pz-server
```

The health `start_period` is 15 minutes so that a first boot is not counted as a
failure.
