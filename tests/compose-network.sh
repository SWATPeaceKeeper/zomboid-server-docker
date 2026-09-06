#!/usr/bin/env bash
# Checks that a container on the Compose network can reach the internet.
#
# This exists because it was once broken in a way nothing else caught. The
# network was declared `internal: true`, which has no route out at all, so
# SteamCMD died with "Steamcmd needs to be online to update" and the documented
# quick start could not work. The image smoke test did not notice: it uses
# `docker run` on the default bridge and never touches the Compose network.
#
# It starts only the backup sidecar, which is small and shares the same network
# as the server, so the check costs seconds rather than a 7 GB download.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="pz-netcheck-$$"
PROBE_URL="${PROBE_URL:-https://api.steampowered.com/ISteamWebAPIUtil/GetServerInfo/v1/}"

export PZ_ADMIN_PASSWORD="network-check-not-a-real-password"
export PZ_RCON_PASSWORD="network-check-not-a-real-password"

cleanup() {
  docker compose -p "${PROJECT}" down --volumes --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

cd "${REPO_ROOT}"

# `run` rather than `up`, because the services set a fixed `container_name` and
# `up` would collide with a stack that is already running on this host.
echo "==> Probing ${PROBE_URL} from the Compose network"
if ! docker compose -p "${PROJECT}" run --rm --no-deps \
  --entrypoint curl pz-backup \
  -fsS --max-time 30 -o /dev/null "${PROBE_URL}"; then
  echo "!! No route to the internet from the Compose network." >&2
  echo "!! The server cannot install itself from Steam like this." >&2
  echo "!! Check that no network in docker-compose.yml is 'internal: true'." >&2
  exit 1
fi

echo "==> Compose network has outbound connectivity"
