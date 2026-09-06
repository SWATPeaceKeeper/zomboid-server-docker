# Project Zomboid Metrics — Design

- **Date:** 2026-09-06
- **Status:** Approved
- **Repository:** `github.com/SWATPeaceKeeper/zomboid-server-docker`
- **Phase:** 2, deferred from the
  [initial design](2026-09-05-pz-docker-server-design.md)

## 1. Purpose

Expose what is happening inside the game and inside the backup pipeline as
Prometheus metrics, so that a server going quiet or a backup silently failing
becomes visible before someone needs either of them.

## 2. What is deliberately not measured here

Container CPU, memory and uptime are already produced by cAdvisor for every
container on the host. Reproducing them in a bespoke exporter would create a
second source for the same number, and two sources that disagree are worse than
one. This design covers only what cAdvisor cannot see: the game and the backups.

Project Zomboid itself is a thin source of truth. Its RCON console offers
`players` and little else in the way of statistics — there is no zombie count, no
tick rate, no world age. Anything beyond the player list would have to come from
parsing the server log, which changes between builds. That is out of scope.

## 3. Architecture

```
┌──────────────┐  RCON   ┌──────────────┐
│  pz-server   │◄────────│ pz-exporter  │──► :9401/metrics   pz_*
│              │         │    (Go)      │
│  :9404 ──────┼─────────┼──────────────┼──► jvm_*  (opt-in)
└──────┬───────┘         └──────┬───────┘
       │                        │ reads, read-only:
       │                        │  /data/server   (build id)
       │                        │  /data/backups  (.status)
┌──────┴───────┐                │
│  pz-backup   │ writes .status ┘
└──────────────┘
```

`pz-exporter` is a third container. It only reads: RCON queries plus two
read-only volume mounts. It has no path to change the server or the backups.

## 4. The exporter

Written in Go, using `prometheus/client_golang` v1.24.x and `gorcon/rcon` v1.4.x
— the same author as the `rcon-cli` the other images already use. Static binary
on a minimal base, built with the digest-pinned `golang:1.27-trixie` builder stage
the repository already uses.

No image size is predicted here. The last time this design process guessed one it
was off by a factor of three, because the figure on Docker Hub is compressed and
the one from `docker images` is not. The size will be measured after the first
build and recorded then.

### File structure

| File | Responsibility |
|---|---|
| `exporter/main.go` | Flag/env parsing, HTTP server, wiring |
| `exporter/internal/players/players.go` | RCON query and parsing of the player list |
| `exporter/internal/backups/backups.go` | Reading and parsing the backup status file |
| `exporter/internal/manifest/manifest.go` | Reading the Steam build id |
| `exporter/internal/collector/collector.go` | Prometheus collector tying the three together |
| `Dockerfile.exporter` | Two-stage build |

Each of the three sources is a pure function over an input it does not own, so
each can be tested without a server, a backup or an install.

### Metrics

| Metric | Type | Meaning |
|---|---|---|
| `pz_up` | gauge | 1 when RCON answered this scrape, 0 otherwise |
| `pz_players_online` | gauge | Number of connected players |
| `pz_player_info{name}` | gauge | Constant 1 per connected player |
| `pz_server_info{build_id}` | gauge | Constant 1, Steam build id as a label |
| `pz_backup_last_run_timestamp_seconds` | gauge | When a backup was last attempted |
| `pz_backup_last_success_timestamp_seconds` | gauge | When one last succeeded |
| `pz_backup_last_size_bytes` | gauge | Size of the most recent archive |
| `pz_backup_count` | gauge | Generations currently kept |
| `pz_scrape_errors_total` | counter | Failed collections, by `source` label |

`pz_player_info` carries player names as labels. With a handful of players that
is harmless; on a busy public server the series count grows with every player who
ever joins, so it can be turned off with `PZ_EXPORT_PLAYER_NAMES=false`.

### Configuration

| Variable | Default | Effect |
|---|---|---|
| `RCON_HOST` | `pz-server` | Server to query |
| `RCON_PORT` | `27015` | |
| `RCON_PASSWORD` | — | Required; without it the exporter refuses to start |
| `RCON_TIMEOUT` | `5s` | Per-scrape timeout |
| `LISTEN_ADDR` | `:9401` | Where `/metrics` is served |
| `PZ_SERVER_DIR` | `/data/server` | Where the Steam manifest is read from |
| `BACKUP_DIR` | `/data/backups` | Where the status file and archives are read from |
| `PZ_EXPORT_PLAYER_NAMES` | `true` | Whether to emit `pz_player_info` |

### Error handling

Collection happens per scrape. Each of the three sources fails independently:

- RCON unreachable → `pz_up 0`, `pz_scrape_errors_total{source="rcon"}` increments,
  player metrics are omitted rather than reported as zero. A server that is down
  is not a server with nobody on it, and the dashboard must not confuse the two.
- Backup status file missing or malformed → backup metrics omitted, error counter
  increments.
- Manifest unreadable → `pz_server_info` omitted, error counter increments.

A failure in one source never blanks the others, and the exporter never returns a
failing HTTP status for a scrape: an exporter that stops answering looks exactly
like an exporter that has been removed.

## 5. How backup failures become visible

Files alone cannot show a *failed* backup — they show what exists, not what is
missing. So the sidecar writes a status file after every run, to
`${BACKUP_DIR}/.status`:

```
timestamp=1788700000
status=ok
archive=/data/backups/pz-20260906-115955.tar.zst
bytes=48291043
```

`status` is `ok`, `failed` or `skipped` (the last covering "no world yet").
This is a deliberately narrow textual contract between two containers: the
sidecar only appends knowledge, the exporter only reads it.

This requires a change to `scripts/backup/backup-now.sh`, which currently reports
its outcome only to the log.

## 6. JVM metrics

Opt-in through `PZ_JMX_METRICS=true` on the **server** container. When set,
`scripts/lib/jvm.sh` — which already edits `vmArgs` to set the heap — additionally
adds the Prometheus JMX Java agent (`prometheus/jmx_exporter` 1.6.x), which serves
`jvm_*` metrics on port 9404: heap by area, garbage collection, threads. No
metric logic is written for this; the agent is the standard tool.

The default is `false`. Without the variable there is no third-party code in the
game's JVM and no additional listener.

The agent jar is added to the server image at build time so that enabling it
needs no network access at runtime.

> **Corrected while planning.** This section first claimed the jar was around
> 600 KB. It is **10.7 MB** — the agent bundles its own dependencies. That is a
> real cost on an image that is otherwise 519 MB, and it is paid by everyone,
> including the majority who leave `PZ_JMX_METRICS` off. The implementation plan
> therefore measures the resulting image and, if the increase is judged not worth
> it, falls back to downloading the jar into the volume on first enable instead of
> baking it in.

## 7. Integration

The repository ships a generic exporter. Wiring it into a specific monitoring
stack is an overlay:

- `docker-compose.monitoring.yml` attaches `pz-exporter` — and, when JMX is on,
  `pz-server` — to an existing external `monitoring` network, so Prometheus can
  reach them without any port being published to the host.
- `grafana/pz-dashboard.json` provides panels for players online, server
  availability, backup age against thresholds, backup size over time, and heap
  when present.

The dashboard deliberately contains no container CPU or memory panels; those
belong to whatever already scrapes cAdvisor.

## 8. Testing

- **Go unit tests** for the three parsers, against captured real output rather
  than invented strings. `gorcon` ships an `rcontest` helper that stands up a fake
  RCON server in-process, so the query path is covered without a game server.
- **The collector** is tested with each source failing in turn, asserting that the
  others still report and that the right error counter moved.
- **`tests/stack-smoke.sh` is extended**: after the server is healthy, the
  exporter's `/metrics` is fetched and must contain `pz_up 1` and
  `pz_players_online 0`. That exercises the exporter against a real server in CI.
- Go code is checked with `go vet` and `gofmt -l` in the lint workflow. A fuller
  linter is deliberately not added until there is noise it would catch.

## 9. Assumptions that must be verified first

Two parts of this design rest on behaviour that has not been observed on a real
installation. Both are cheap to check once, and the implementation plan resolves
them before building on them.

1. **The Steam build id lives in `steamapps/appmanifest_380870.acf` under a
   `buildid` key.** This is standard SteamCMD behaviour but has not been confirmed
   against this install. If it does not hold, `pz_server_info` is dropped; nothing
   else depends on it.
2. **The exact output format of the RCON `players` command is unknown.** The
   parser must be written against captured real output, not against a guess. The
   first implementation task captures it from a running server in CI and commits
   it as a test fixture.

### Verdict, 2026-09-06

Both were checked against a Build 42 server in CI run
[34033815919](https://github.com/SWATPeaceKeeper/zomboid-server-docker/actions/runs/34033815919).

1. **Confirmed.** The manifest contains `"buildid"  "24909836"`. `pz_server_info`
   stays in the design.
2. **Partly confirmed.** An empty server prints exactly `Players connected (0):`
   — a header carrying the count in brackets, as assumed. The shape of the *name*
   lines could not be observed, because CI cannot make a player join. It is taken
   from `beyenilmez/pz-info-api`, an independent project that parses the same
   command against real servers, which documents and handles `- name` lines. The
   fixture is labelled as reconstructed rather than captured in
   `exporter/testdata/README.md`, so a future failure is traced to the right
   place.

The same capture also settled a question left open in the README: `players` and
`quit` are confirmed present in the server's own `help` output.

## 10. Out of scope

Alerting rules, per-player playtime, zombie or world statistics (the game does
not expose them), mod update detection, and long-term metric storage.

## 11. Risks

| Risk | Mitigation |
|---|---|
| `players` output changes between builds and the parser breaks | Parser tested against a captured fixture; the stack smoke test would catch a total failure |
| Player-name labels grow unbounded on a public server | `PZ_EXPORT_PLAYER_NAMES=false` |
| The JMX agent destabilises the game JVM | Opt-in, off by default, and separable from every other metric |
| RCON query on every scrape adds load | One short-lived connection per scrape with a 5 s timeout; `players` is a cheap command |
