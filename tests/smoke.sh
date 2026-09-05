#!/usr/bin/env bash
# End-to-end test: the server installs, becomes healthy, saves and shuts down
# cleanly. This is the check that a published image is actually usable.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${SMOKE_IMAGE:-pz-server:smoke}"
CONTAINER="pz-smoke-$$"
RCON_PASSWORD="smoke-rcon-password"
READY_TIMEOUT="${SMOKE_TIMEOUT:-1200}"

cleanup() {
  docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
  docker volume rm -f "${CONTAINER}-server" "${CONTAINER}-data" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> Building ${IMAGE}"
docker build -t "${IMAGE}" "${REPO_ROOT}"

echo "==> Starting ${CONTAINER}"
docker volume create "${CONTAINER}-server" >/dev/null
docker volume create "${CONTAINER}-data" >/dev/null
docker run --detach \
  --name "${CONTAINER}" \
  --volume "${CONTAINER}-server:/data/server" \
  --volume "${CONTAINER}-data:/data/zomboid" \
  --env "ADMIN_PASSWORD=smoke-admin-password" \
  --env "RCON_PASSWORD=${RCON_PASSWORD}" \
  --env "SERVER_NAME=smoketest" \
  --env "PZ_MAX_RAM=2g" \
  "${IMAGE}" >/dev/null

echo "==> Waiting up to ${READY_TIMEOUT}s for the container to become healthy"
deadline=$(($(date +%s) + READY_TIMEOUT))
while true; do
  state="$(docker inspect -f '{{.State.Health.Status}}' "${CONTAINER}" 2>/dev/null || echo missing)"
  running="$(docker inspect -f '{{.State.Running}}' "${CONTAINER}" 2>/dev/null || echo false)"
  if [ "${state}" = "healthy" ]; then
    break
  fi
  if [ "${running}" != "true" ]; then
    echo "!! Container exited before becoming healthy" >&2
    docker logs "${CONTAINER}" >&2
    exit 1
  fi
  if [ "$(date +%s)" -ge "${deadline}" ]; then
    echo "!! Timed out waiting for health (last state: ${state})" >&2
    docker logs --tail 100 "${CONTAINER}" >&2
    exit 1
  fi
  sleep 10
done
echo "==> Healthy"

echo "==> Saving the world over RCON"
docker exec "${CONTAINER}" rcon -a "127.0.0.1:27015" -p "${RCON_PASSWORD}" save

echo "==> Stopping the container and checking the shutdown is clean"
docker stop --timeout 180 "${CONTAINER}" >/dev/null
exit_code="$(docker inspect -f '{{.State.ExitCode}}' "${CONTAINER}")"
if [ "${exit_code}" != "0" ]; then
  echo "!! Container exited with ${exit_code}, expected 0" >&2
  docker logs --tail 100 "${CONTAINER}" >&2
  exit 1
fi

if ! docker logs "${CONTAINER}" 2>&1 | grep -q "Server stopped cleanly"; then
  echo "!! Shutdown handler did not report a clean stop" >&2
  exit 1
fi

echo "==> Checking the world was written"
save_count="$(docker run --rm \
  --volume "${CONTAINER}-data:/data/zomboid" \
  --entrypoint /bin/bash "${IMAGE}" \
  -c 'find /data/zomboid/Saves -type f 2>/dev/null | wc -l')"
if [ "${save_count}" -lt 1 ]; then
  echo "!! Saves directory is empty after a clean shutdown" >&2
  exit 1
fi

echo "==> Smoke test passed (${save_count} files under Saves/)"
