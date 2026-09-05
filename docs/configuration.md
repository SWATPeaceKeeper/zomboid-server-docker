# Configuration

## Server container

| Variable | Default | Effect |
|---|---|---|
| `PZ_BRANCH` | `public` | Steam branch. `public` is Build 42, `legacy41` is Build 41. Applied on every start when `UPDATE_ON_START` is true. |
| `PZ_MAX_RAM` | `4g` | JVM heap, written into `ProjectZomboid64.json` as both `-Xms` and `-Xmx`. See the memory table in the README before raising it. |
| `UPDATE_ON_START` | `true` | Runs SteamCMD on every start. Set to `false` to freeze the installed version and update during a maintenance window instead. |
| `SERVER_NAME` | `servertest` | Selects the config set and the save folder: `<name>.ini`, `<name>_SandboxVars.lua`, `Saves/Multiplayer/<name>`. Changing it starts a new world. |
| `ADMIN_USERNAME` | `admin` | Admin account name, used on the first boot only. |
| `ADMIN_PASSWORD` | — | **Required.** Used on the first boot only; see the note below. |
| `SERVER_PASSWORD` | empty | Password players need to join. Empty means no password. Written to `Password`. |
| `RCON_PASSWORD` | — | **Required** for the healthcheck and the backup sidecar. Written to `RCONPassword`. |
| `RCON_PORT` | `27015` | Written to `RCONPort`. Never published to the host. |
| `GAME_PORT` | `16261` | Written to `DefaultPort`. |
| `UDP_PORT` | `16262` | Written to `UDPPort`. Has no command-line equivalent, so it can only be set through the INI. |
| `PUBLIC` | `false` | Lists the server in the in-game browser. Written to `Public`. |
| `PUBLIC_NAME` | `Project Zomboid Server` | Display name in that browser. Written to `PublicName`. |
| `MAX_PLAYERS` | `16` | Written to `MaxPlayers`. |
| `MOD_IDS` | empty | Written to `Mods`. Internal mod ids, backslash-prefixed on Build 42. |
| `WORKSHOP_IDS` | empty | Written to `WorkshopItems`. Numeric Steam Workshop ids. |
| `SELF_MANAGED_MODS` | `false` | When true, `Mods` and `WorkshopItems` are left alone entirely. |
| `NOSTEAM` | `false` | Passes `-nosteam`. Note this also disables Workshop downloads. |
| `MODFOLDERS` | unset | Passes `-modfolders`, controlling where mods are loaded from and in what order. |
| `STEAM_RETRIES` | `3` | SteamCMD attempts before the container gives up. |
| `STEAM_RETRY_DELAY` | `15` | Seconds between those attempts. |
| `PZ_SERVER_DIR` | `/data/server` | Installation directory. Change only if you remap the volumes. |
| `PZ_DATA_DIR` | `/data/zomboid` | Config, saves and logs. Passed to the server as `-cachedir=`. |
| `TZ` | `Europe/Berlin` | Container timezone, which is what log timestamps use. |

### About `ADMIN_PASSWORD`

It is passed on the command line **only on the very first boot**, detected by the
absence of `db/<SERVER_NAME>.db`. The server writes its full command line into the
log in clear text on every start, so passing it every time would copy the password
into every log file for no benefit — after the first boot the account lives in the
world database.

To change it later, use `/changepwd` in-game as the admin, or delete the world
database and start over.

## Backup sidecar

| Variable | Default | Effect |
|---|---|---|
| `BACKUP_INTERVAL` | `6h` | Time between scheduled backups. Accepts `90`, `30s`, `15m`, `6h`, `1d`. |
| `BACKUP_KEEP` | `14` | Generations to keep. Older ones are deleted after each run. |
| `BACKUP_MODE` | `tar` | `tar` writes `.tar.zst` archives, `dir` writes a plain directory copy. See `backup-restore.md`. |
| `BACKUP_ON_START` | `true` | Takes a backup when the sidecar starts, capturing the state before the freshly started server writes to it. |
| `BACKUP_SAVE_WAIT` | `20` | Seconds to wait after the RCON `save` before archiving, because the save is asynchronous. |
| `BACKUP_DIR` | `/data/backups` | Where backups are written. |
| `RCON_HOST` | `pz-server` | Service name of the server container. |
| `RCON_PORT` | `27015` | Must match the server. |
| `RCON_PASSWORD` | — | **Required.** Without it the sidecar backs up without asking the server to save first, and says so in the log. |
| `NTFY_URL` | unset | When set, backup failures are posted here. Unset means nothing external is contacted. |
| `NTFY_TOKEN` | unset | Bearer token for that endpoint, if it needs one. |

## What the container does and does not touch

**Patched on every start**, from the variables above: `Password`, `RCONPassword`,
`RCONPort`, `Public`, `PublicName`, `MaxPlayers`, `DefaultPort`, `UDPPort`, and —
unless `SELF_MANAGED_MODS` is set — `Mods` and `WorkshopItems`.

**Never touched**: every other key in `<SERVER_NAME>.ini`, the whole of
`<SERVER_NAME>_SandboxVars.lua`, and the whole of
`<SERVER_NAME>_spawnregions.lua`. Comments, ordering and settings this image has
never heard of all survive, which matters because Project Zomboid adds INI keys
between builds.

To change any of those, edit the files in the `pz-zomboid` volume and restart:

```bash
docker compose stop pz-server
docker run --rm -it -v zomboid-server-docker_pz-zomboid:/data/zomboid \
  -w /data/zomboid/Server alpine vi servertest_SandboxVars.lua
docker compose start pz-server
```

An INI key that is written by the container will be overwritten again on the next
start. Set it through the environment instead, or use `SELF_MANAGED_MODS` for the
mod lines.

## Bind mounts instead of named volumes

The Compose file uses named volumes. If you prefer host directories, they must be
owned by uid/gid 1000, because the container never runs as root and does not
chown anything at startup:

```bash
mkdir -p ./data/server ./data/zomboid ./data/backups
sudo chown -R 1000:1000 ./data
```

Without that, the container stops immediately with a message naming the directory
that is not writable.
