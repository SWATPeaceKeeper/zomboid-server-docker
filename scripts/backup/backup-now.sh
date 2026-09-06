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

# Records the outcome of this run where the exporter can see it. Written for
# every outcome, because "nothing changed since yesterday" and "yesterday's backup
# failed" have to be distinguishable from the outside.
write_status() {
  local state="$1" archive="${2:-}" bytes="${3:-0}"
  local status_file="${BACKUP_DIR}/.status"

  mkdir -p "${BACKUP_DIR}"
  {
    printf 'timestamp=%s\n' "$(date -u +%s)"
    printf 'status=%s\n' "${state}"
    printf 'archive=%s\n' "${archive}"
    printf 'bytes=%s\n' "${bytes}"
  } >"${status_file}.tmp"

  # Renamed into place so a reader never catches a half-written file.
  mv "${status_file}.tmp" "${status_file}"
}

main() {
  local archive status=0 bytes=0
  save_world
  archive="$(backup_create "${PZ_DATA_DIR}" "${BACKUP_DIR}" "${BACKUP_MODE}")" || status=$?

  # 2 is "no world yet", which happens on a fresh deployment while the server is
  # still installing. It is reported back so the scheduler can stay quiet, but it
  # is not a failure worth notifying anyone about.
  if [ "${status}" -eq 2 ]; then
    write_status "skipped"
    return 2
  fi
  if [ "${status}" -ne 0 ]; then
    write_status "failed"
    backup_notify "failure" "Backup failed; see the container log."
    return 1
  fi

  bytes="$(du -sb "${archive}" 2>/dev/null | cut -f1)"
  write_status "ok" "${archive}" "${bytes:-0}"
  log_info "Created ${archive}"
  backup_rotate "${BACKUP_DIR}" "${BACKUP_KEEP}"
}

main "$@"
