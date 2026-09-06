#!/usr/bin/env bash
# End-to-end test of the Compose stack, which is what the documentation tells
# people to run.
#
# tests/smoke.sh covers the image through `docker run`. That is a different path:
# it uses the default bridge and no sidecar, so it cannot catch a broken Compose
# network, a wrong service name or a backup sidecar that never reaches RCON. All
# three of those were real.
#
# The interesting assertion is step 3: the sidecar must report that the *server*
# acknowledged the save. Backing up without that works, but silently produces an
# archive that can be missing the most recent play.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
READY_TIMEOUT="${STACK_TIMEOUT:-2400}"

export PZ_ADMIN_PASSWORD="${PZ_ADMIN_PASSWORD:-stack-smoke-admin-password}"
export PZ_RCON_PASSWORD="${PZ_RCON_PASSWORD:-stack-smoke-rcon-password}"
export SERVER_NAME="${SERVER_NAME:-stacksmoke}"
export PZ_MAX_RAM="${PZ_MAX_RAM:-3g}"

cd "${REPO_ROOT}"

cleanup() {
  docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

# The Compose file pins container names, so a stack that is already up would
# collide and the failure would look like a bug in this test.
if docker ps --all --format '{{.Names}}' | grep -qx 'pz-server'; then
  echo "!! A container named pz-server already exists. Stop it first." >&2
  exit 1
fi

echo "==> Bringing the stack up"
docker compose up -d

echo "==> Waiting up to ${READY_TIMEOUT}s for pz-server to become healthy"
deadline=$(($(date +%s) + READY_TIMEOUT))
while true; do
  state="$(docker inspect -f '{{.State.Health.Status}}' pz-server 2>/dev/null || echo missing)"
  running="$(docker inspect -f '{{.State.Running}}' pz-server 2>/dev/null || echo false)"
  if [ "${state}" = "healthy" ]; then
    break
  fi
  if [ "${running}" != "true" ]; then
    echo "!! pz-server exited before becoming healthy" >&2
    docker compose logs --tail 100 pz-server >&2
    exit 1
  fi
  if [ "$(date +%s)" -ge "${deadline}" ]; then
    echo "!! Timed out waiting for health (last state: ${state})" >&2
    docker compose logs --tail 100 pz-server >&2
    exit 1
  fi
  sleep 10
done
echo "==> Healthy"

echo "==> Taking a backup against the running server"
backup_output="$(docker compose exec -T pz-backup backup-now 2>&1)"
printf '%s\n' "${backup_output}"

if ! printf '%s' "${backup_output}" | grep -q "Server acknowledged the save command"; then
  echo "!! The sidecar could not reach the server over RCON." >&2
  echo "!! The backup would be missing the most recent changes." >&2
  exit 1
fi

if ! printf '%s' "${backup_output}" | grep -q "INFO: Created "; then
  echo "!! The sidecar reported no archive." >&2
  exit 1
fi

echo "==> Checking the archive exists and is not empty"
archive_count="$(docker compose exec -T pz-backup \
  sh -c 'find /data/backups -name "pz-*" -size +1k | wc -l')"
if [ "${archive_count//[[:space:]]/}" -lt 1 ]; then
  echo "!! No non-empty backup in /data/backups" >&2
  docker compose exec -T pz-backup ls -l /data/backups >&2
  exit 1
fi

echo "==> Stopping the stack and checking the shutdown is clean"
docker compose stop
exit_code="$(docker inspect -f '{{.State.ExitCode}}' pz-server)"
if [ "${exit_code}" != "0" ]; then
  echo "!! pz-server exited with ${exit_code}, expected 0" >&2
  docker compose logs --tail 100 pz-server >&2
  exit 1
fi

if ! docker compose logs pz-server 2>&1 | grep -q "Server stopped cleanly"; then
  echo "!! The shutdown handler did not report a clean stop" >&2
  exit 1
fi

echo "==> Checking the world was written"
save_count="$(docker compose run --rm --no-deps --entrypoint /bin/bash pz-server \
  -c 'find /data/zomboid/Saves -type f 2>/dev/null | wc -l')"
if [ "${save_count//[[:space:]]/}" -lt 1 ]; then
  echo "!! Saves directory is empty after a clean shutdown" >&2
  exit 1
fi

echo "==> Stack smoke test passed (${save_count//[[:space:]]/} files under Saves/)"
