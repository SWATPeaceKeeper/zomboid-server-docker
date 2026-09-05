#!/usr/bin/env bash
# Takes a single backup: save over RCON, archive, rotate. Usable directly via
# `docker compose exec pz-backup backup-now`.
set -euo pipefail

# Resolved through readlink because this script is also reachable as the symlink
# /usr/local/bin/backup-now. Without it BASH_SOURCE points at the symlink and the
# library paths below resolve into /usr/local/lib, which does not exist.
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/log.sh
source "${SCRIPT_DIR}/../lib/log.sh"
# shellcheck source=lib/backup.sh
source "${SCRIPT_DIR}/lib/backup.sh"

PZ_DATA_DIR="${PZ_DATA_DIR:-/data/zomboid}"
BACKUP_DIR="${BACKUP_DIR:-/data/backups}"
BACKUP_MODE="${BACKUP_MODE:-tar}"
BACKUP_KEEP="${BACKUP_KEEP:-14}"
RCON_BIN="${RCON_BIN:-rcon}"
RCON_HOST="${RCON_HOST:-pz-server}"
RCON_PORT="${RCON_PORT:-27015}"

# Asks the server to flush the world to disk. A backup taken without this is
# still useful, so a missing or unreachable RCON is a warning, not an error.
save_world() {
  if [ -z "${RCON_PASSWORD:-}" ]; then
    log_warn "RCON_PASSWORD is not set; backing up without asking the server" \
      "to save first. The archive may be missing the most recent changes."
    return 0
  fi
  if "${RCON_BIN}" -a "${RCON_HOST}:${RCON_PORT}" -p "${RCON_PASSWORD}" \
    save >/dev/null 2>&1; then
    log_info "Server acknowledged the save command"
    # The save is asynchronous; give it a moment to reach disk before archiving.
    sleep "${BACKUP_SAVE_WAIT:-20}"
    return 0
  fi
  log_warn "Could not reach RCON at ${RCON_HOST}:${RCON_PORT}; backing up anyway"
}

main() {
  local archive
  save_world
  if ! archive="$(backup_create "${PZ_DATA_DIR}" "${BACKUP_DIR}" "${BACKUP_MODE}")"; then
    backup_notify "failure" "Backup failed; see the container log."
    return 1
  fi
  log_info "Created ${archive}"
  backup_rotate "${BACKUP_DIR}" "${BACKUP_KEEP}"
}

main "$@"
