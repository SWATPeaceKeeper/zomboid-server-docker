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
# Deliberately not the default. The default path - no agent in the JVM - is
# covered by the release workflow's check of the published image, so turning it
# on here means both paths are exercised somewhere rather than only the easy one.
export PZ_JMX_METRICS="${PZ_JMX_METRICS:-true}"

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
# --build is not optional here. The services carry both `image:` and `build:`,
# and Compose's default pull policy prefers the published image over the local
# source, so without it this test silently verifies the last release instead of
# the code under test. That is exactly how a change to the backup sidecar passed
# review while its container ran month-old code.
docker compose up -d --build

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

echo "==> Checking the exporter answers against the live server"
metrics="$(docker compose exec -T pz-exporter \
  wget -qO- http://127.0.0.1:9401/metrics)"

if ! printf '%s' "${metrics}" | grep -qE '^pz_up 1$'; then
  echo "!! pz_up is not 1; the exporter cannot reach the server over RCON" >&2
  printf '%s\n' "${metrics}" | grep -E '^pz_' >&2
  exit 1
fi

if ! printf '%s' "${metrics}" | grep -qE '^pz_players_online 0$'; then
  echo "!! pz_players_online missing or not zero on an empty server" >&2
  printf '%s\n' "${metrics}" | grep -E '^pz_' >&2
  exit 1
fi

# The valuable one: it proves the sidecar and the exporter agree about a backup
# that really happened moments ago in this same run.
if ! printf '%s' "${metrics}" | grep -q '^pz_backup_last_success_timestamp_seconds '; then
  echo "!! the exporter did not see the backup taken moments ago" >&2
  printf '%s\n' "${metrics}" | grep -E '^pz_' >&2
  exit 1
fi

if ! printf '%s' "${metrics}" | grep -q '^pz_server_info{build_id='; then
  echo "!! the exporter could not read the steam build id" >&2
  printf '%s\n' "${metrics}" | grep -E '^pz_' >&2
  exit 1
fi
echo "==> Exporter reports pz_up 1, the backup and the build id"

echo "==> Checking the JMX agent loaded into the game JVM"
jvm_metrics="$(docker compose exec -T pz-exporter \
  wget -qO- http://pz-server:9404/metrics 2>/dev/null || true)"
# The metric is jvm_memory_used_bytes, not jvm_memory_bytes_used: the Prometheus
# Java client renamed it between 0.x and 1.x. Both are checked so that a future
# rename fails with a clear message rather than looking like a broken agent.
if ! printf '%s' "${jvm_metrics}" | grep -qE '^jvm_memory_(used_bytes|bytes_used)'; then
  echo "!! No jvm heap metrics on pz-server:9404 although PZ_JMX_METRICS is true." >&2
  echo "-- jvm_ metric names actually served --" >&2
  printf '%s\n' "${jvm_metrics}" | grep -oE '^jvm_[a-z_]+' | sort -u | head -15 >&2 || true

  echo "-- the agent argument in ProjectZomboid64.json --" >&2
  docker compose exec -T pz-server \
    sh -c 'grep -o "javaagent[^\"]*" /data/server/ProjectZomboid64.json' >&2 || true

  # Distinguishes "the JVM never loaded the agent" from "it loaded but is not
  # reachable from another container", which need opposite fixes.
  echo "-- the java command line as actually started --" >&2
  docker compose exec -T pz-server \
    sh -c 'cat /proc/$(pgrep -f ProjectZomboid | head -1)/cmdline | tr "\0" " "' >&2 || true

  echo "-- listening sockets inside pz-server --" >&2
  docker compose exec -T pz-server ss -lntp >&2 || true

  # The server image has neither curl nor wget, so this uses bash's own TCP
  # support rather than adding a package just to debug.
  echo "-- is anything listening on 9404 inside pz-server? --" >&2
  docker compose exec -T pz-server \
    bash -c 'exec 3<>/dev/tcp/127.0.0.1/9404 && echo "port 9404 open" || echo "port 9404 closed"' >&2 || true

  echo "-- anything the server said about the agent --" >&2
  docker compose logs pz-server 2>&1 | grep -iE 'agent|jmx|prometheus' | head -20 >&2 || true

  exit 1
fi
echo "==> JMX agent is serving jvm heap metrics"

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
