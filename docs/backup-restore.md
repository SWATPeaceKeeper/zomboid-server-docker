# Backups and restore

## What is backed up

From the data volume (`/data/zomboid`):

- `Saves/` — the world itself, including player data
- `Server/` — `<name>.ini`, `<name>_SandboxVars.lua`, `<name>_spawnregions.lua`

Not backed up: the Steam installation and the downloaded Workshop content. Both
are re-downloadable and would multiply the size of every archive for nothing.

## When backups happen

- **On start**, if `BACKUP_ON_START=true` (the default). This captures the state
  before the freshly started server writes to it, which in practice is the state
  of the last clean shutdown. It is deliberately done this way rather than trying
  to trigger a backup during shutdown, which is racy across container boundaries.
- **Every `BACKUP_INTERVAL`**, six hours by default.
- **On demand:**

  ```bash
  docker compose exec pz-backup backup-now
  ```

Before each one the sidecar issues `save` over RCON and waits `BACKUP_SAVE_WAIT`
seconds, because the server writes the world asynchronously. Without
`RCON_PASSWORD` it still takes the backup, but warns that recent changes may be
missing.

A failed backup exits non-zero, logs the reason, and — if `NTFY_URL` is set —
sends a notification. It never reports success for an archive that was not
written.

## Choosing a mode

| | `BACKUP_MODE=tar` (default) | `BACKUP_MODE=dir` |
|---|---|---|
| Output | `pz-<timestamp>.tar.zst` | `pz-<timestamp>/` |
| Self-contained | Yes | Yes |
| Disk use per generation | Small | Full size |
| Works well with Borg/restic | **No** | **Yes** |

Compression randomises the bytes, so every `.tar.zst` looks like an entirely new
file to a deduplicating backup tool: fourteen generations means fourteen full
copies in the repository. A directory tree changes only where the world changed,
which is what Borg is built for.

Use `tar` when the backup directory is all you have. Use `dir` when a host-level
tool already backs that directory up.

## borgmatic

Set `BACKUP_MODE=dir`, then point borgmatic at the host path behind the
`pz-backups` volume:

```yaml
source_directories:
  - /var/lib/docker/volumes/pz-docker-server_pz-backups/_data

exclude_patterns:
  - '*.tar.zst'
```

Reading a Docker volume path directly works but is awkward. Mapping the backup
volume to a real host directory is clearer:

```yaml
# docker-compose.override.yml
services:
  pz-backup:
    volumes:
      - /srv/pz-backups:/data/backups
```

```bash
sudo mkdir -p /srv/pz-backups && sudo chown -R 1000:1000 /srv/pz-backups
```

Then borgmatic backs up `/srv/pz-backups` like any other directory, and
`BACKUP_KEEP` controls how many generations it sees.

## Restore

**Try this once before you need it.** A restore procedure that has never been run
is a guess.

1. Stop the stack. This saves the world first, so nothing is lost by stopping.

   ```bash
   docker compose down
   ```

2. Find the archive you want.

   ```bash
   docker run --rm -v pz-docker-server_pz-backups:/b alpine ls -lh /b
   ```

3. Empty the data volume. Everything in it is about to be replaced.

   ```bash
   docker run --rm -v pz-docker-server_pz-zomboid:/data/zomboid alpine \
     sh -c 'rm -rf /data/zomboid/Saves /data/zomboid/Server'
   ```

4. Extract the archive back into it. For `tar` mode:

   ```bash
   docker run --rm \
     -v pz-docker-server_pz-zomboid:/data/zomboid \
     -v pz-docker-server_pz-backups:/b \
     ghcr.io/swatpeacekeeper/pz-docker-server-backup:latest \
     tar --use-compress-program=zstd -xf /b/pz-20260905-060000.tar.zst -C /data/zomboid
   ```

   For `dir` mode:

   ```bash
   docker run --rm \
     -v pz-docker-server_pz-zomboid:/data/zomboid \
     -v pz-docker-server_pz-backups:/b \
     alpine sh -c 'cp -a /b/pz-20260905-060000/. /data/zomboid/'
   ```

5. Fix ownership. The container runs as uid 1000 and will refuse to start
   otherwise.

   ```bash
   docker run --rm -v pz-docker-server_pz-zomboid:/data/zomboid alpine \
     chown -R 1000:1000 /data/zomboid
   ```

6. Start the stack and confirm the world loads.

   ```bash
   docker compose up -d
   docker compose logs -f pz-server
   ```

   Wait for the container to report `healthy`, then join and check that the map
   and your character are the ones you expected.

If step 6 shows a fresh world instead of the restored one, the most likely cause
is a `SERVER_NAME` that does not match the archive: the save lives under
`Saves/Multiplayer/<SERVER_NAME>`, and a different name means a different world.
