# Security policy

## Reporting a vulnerability

Report it privately through GitHub:
**[Security → Report a vulnerability](https://github.com/SWATPeaceKeeper/zomboid-server-docker/security/advisories/new)**.

Please do not open a public issue for something that would let someone take over
a running server before there is a fix.

What helps:

- Which image and tag (`docker inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' pz-server`).
- What an attacker needs in order to reach it: the internet, the Docker host,
  the Compose network, or an account on the game server.
- The smallest set of steps that shows the problem.

Expect an acknowledgement within a week. This is a hobby project maintained by
one person, so a fix takes as long as it takes; you will be told where it
stands. If you would like credit in the advisory, say so.

## Supported versions

| Version | Supported |
|---|---|
| Latest `1.x` release | Yes |
| Older `1.x` releases | No — upgrade to the newest patch |
| `edge` (current `main`) | Yes, but it is unreleased by definition |

Fixes go onto `main` and into the next release. There are no backports to older
minors.

Note that a version tag pins **this wrapper**, not Project Zomboid. With the
default `UPDATE_ON_START=true` the game updates itself from Steam on every
start, regardless of which image tag you run.

## Scope

**In scope** — anything this repository actually controls:

- The entrypoint, healthcheck and library scripts under `scripts/`.
- The backup sidecar, including archive handling and rotation.
- The metrics exporter under `exporter/`.
- The three Dockerfiles and the images published from them.
- `docker-compose.yml` and the monitoring overlay, as shipped.
- The GitHub Actions workflows and the release pipeline.

**Out of scope** — real problems, but not ones that can be fixed here:

- Project Zomboid itself, its RCON implementation, and its own network
  protocol. Report those to [The Indie Stone](https://theindiestone.com/).
- SteamCMD and the Steam content servers.
- Steam Workshop mods. A mod runs inside the game's JVM with the same
  privileges as the server; the wrapper cannot sandbox it. Install mods you
  trust.
- Vulnerabilities in the upstream base images that have no fixed version yet.
  Trivy is run with `ignore-unfixed`, so these are visible but do not block a
  release.
- A deployment that publishes RCON to the internet, or one with a guessable
  password. See below.

## What the images already do

So you know what you are getting and what is left to you:

- Both service containers run as **uid/gid 1000, never root**, with
  `no-new-privileges:true` in the shipped Compose file.
- **RCON is not published to the host.** Only the two UDP game ports are.
- The exporter mounts everything **read-only** and runs `FROM scratch` — no
  shell, no package manager, no packages to carry advisories.
- **Every base image is pinned by digest**, and third-party Go binaries are
  compiled from source in a builder stage rather than taken from years-old
  release tarballs.
- **Trivy scans each image for HIGH and CRITICAL findings before it is
  published**, and is allowed to fail the build. There is no
  `continue-on-error` on the scanner: a broken scanner and a clean scan must not
  look the same.
- **The admin password is passed to the game only on the very first boot**,
  because Project Zomboid writes its whole command line into the log in clear
  text on every start.
- The JMX metrics agent is **off by default**. It loads third-party code into
  the game's JVM and opens a listener, which nobody should pay for who did not
  ask for it.

## What is left to you

The two things most likely to go wrong in a real deployment:

1. **Do not forward port 27015.** That is RCON — full remote administration of
   your server, over a protocol with no transport encryption. Forward
   `16261/udp` and `16262/udp` and nothing else.
2. **Use long, unique passwords** for `PZ_ADMIN_PASSWORD` and
   `PZ_RCON_PASSWORD`, keep them in a gitignored `.env`, and never reuse them
   from somewhere else. Compose refuses to start without them rather than
   quietly bringing up a server anyone who finds it can administer.

Also worth knowing:

- **Passwords are passed as environment variables.** They are therefore visible
  in `docker inspect` and to anything that can reach the Docker socket. Treat
  access to the Docker socket as equivalent to admin on the game server.
- **`pz_player_info` exports player names as Prometheus labels.** On a public
  server that is both a cardinality problem and a privacy one — set
  `PZ_EXPORT_PLAYER_NAMES=false`.
- **Backups are not encrypted.** `.tar.zst` archives in a Docker volume. If the
  world data matters to you, point a real backup tool at
  `BACKUP_MODE=dir` output.
- **A Steam Workshop mod is code you are running.** It executes inside the
  server JVM, with the server's file access.

## AI assistance

This project is developed with AI assistance; see [AI-POLICY.md](AI-POLICY.md).
It changes nothing about the above: security statements here are backed by a
scanner run or by configuration you can read in this repository, or they are not
made.
