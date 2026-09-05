#!/usr/bin/env bash
# Scheduling loop for world backups.
set -euo pipefail

# Resolved through readlink so the script keeps working when reached through a
# symlink, the way backup-now.sh is.
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/log.sh
source "${SCRIPT_DIR}/../lib/log.sh"
# shellcheck source=lib/backup.sh
source "${SCRIPT_DIR}/lib/backup.sh"

BACKUP_INTERVAL="${BACKUP_INTERVAL:-6h}"
BACKUP_ON_START="${BACKUP_ON_START:-true}"

TERMINATE=""
handle_term() {
  TERMINATE=1
  log_info "Shutdown requested, finishing the current cycle"
}
trap handle_term TERM INT

main() {
  local interval_seconds
  interval_seconds="$(backup_duration_to_seconds "${BACKUP_INTERVAL}")"
  log_info "Backup loop started, interval ${BACKUP_INTERVAL} (${interval_seconds}s)"

  # A backup taken at start captures the state before the freshly started server
  # writes to it, which is in practice the state of the last clean shutdown.
  if [ "${BACKUP_ON_START}" = "true" ]; then
    "${SCRIPT_DIR}/backup-now.sh" || log_error "Startup backup failed"
  fi

  while [ -z "${TERMINATE}" ]; do
    # Sleeping in the background and waiting on it lets a signal interrupt the
    # wait immediately instead of after a full interval.
    sleep "${interval_seconds}" &
    wait $! || true
    if [ -n "${TERMINATE}" ]; then
      break
    fi
    "${SCRIPT_DIR}/backup-now.sh" || log_error "Scheduled backup failed"
  done

  log_info "Backup loop stopped"
}

main "$@"
