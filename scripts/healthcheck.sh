#!/usr/bin/env bash
# Reports whether the server actually accepts players, not merely whether the
# JVM process is alive.
set -uo pipefail

RCON_BIN="${RCON_BIN:-rcon}"
RCON_PORT="${RCON_PORT:-27015}"
GAME_PORT="${GAME_PORT:-16261}"

if [ -n "${RCON_PASSWORD:-}" ]; then
  # Output is discarded: it would otherwise end up in `docker inspect` health
  # logs, and the reply can contain player names.
  if "${RCON_BIN}" -a "127.0.0.1:${RCON_PORT}" -p "${RCON_PASSWORD}" \
    players >/dev/null 2>&1; then
    exit 0
  fi
  echo "RCON did not answer on port ${RCON_PORT}"
  exit 1
fi

# Fallback for servers without RCON. Weaker, because a JVM that is still
# generating the world also passes it once the socket is bound.
if ! pgrep -f "ProjectZomboid" >/dev/null 2>&1; then
  echo "No ProjectZomboid process found"
  exit 1
fi

# `grep … >/dev/null`, not `grep -q …`. `ss` output here is a handful of lines,
# so -q could not realistically outrun it — but the pattern is the one that made
# the stack test report a metric as missing while printing it, and a false
# "unhealthy" restarts a server. No reason to keep the trap.
if ! ss -lun 2>/dev/null | grep ":${GAME_PORT}" >/dev/null; then
  echo "UDP port ${GAME_PORT} is not bound"
  exit 1
fi

exit 0
