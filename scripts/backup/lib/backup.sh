#!/usr/bin/env bash
# World backup: archive creation, rotation and optional notification.

# Converts 90 / 30s / 15m / 6h / 1d into seconds.
backup_duration_to_seconds() {
  local value="${1:-}" number unit
  if [[ "${value}" =~ ^([0-9]+)([smhd]?)$ ]]; then
    number="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
  else
    log_error "Cannot parse duration '${value}'. Use 90, 30s, 15m, 6h or 1d."
    return 1
  fi

  case "${unit}" in
  "" | s) printf '%s\n' "${number}" ;;
  m) printf '%s\n' "$((number * 60))" ;;
  h) printf '%s\n' "$((number * 3600))" ;;
  d) printf '%s\n' "$((number * 86400))" ;;
  esac
}

# Creates a backup and prints its path. `dir` mode exists because deduplicating
# backup tools such as Borg handle a plain directory far better than a fresh
# compressed archive on every run.
backup_create() {
  local data_dir="$1" backup_dir="$2" mode="$3"
  local stamp target sources=()

  # Exit code 2 means "there is nothing to back up yet", which is what a brand
  # new deployment looks like while the server is still installing. Callers can
  # tell it apart from a real failure (1) and stay quiet about it.
  if [ ! -d "${data_dir}/Saves" ]; then
    log_warn "No world in ${data_dir} yet; nothing to back up."
    return 2
  fi

  # The Server directory only appears once the server has written its config, so
  # a backup taken very early must not fail on its absence.
  sources+=("Saves")
  if [ -d "${data_dir}/Server" ]; then
    sources+=("Server")
  fi

  stamp="$(date -u +%Y%m%d-%H%M%S)"
  mkdir -p "${backup_dir}"

  # Every branch below is checked explicitly. A backup tool that prints a path
  # for an archive its archiver failed to write is worse than one that crashes:
  # the failure only surfaces when the backup is needed.
  case "${mode}" in
  tar)
    target="${backup_dir}/pz-${stamp}.tar.zst"
    if ! tar --use-compress-program=zstd \
      -cf "${target}" -C "${data_dir}" "${sources[@]}"; then
      log_error "Creating ${target} failed; removing the partial archive."
      rm -f "${target}"
      return 1
    fi
    ;;
  dir)
    target="${backup_dir}/pz-${stamp}"
    mkdir -p "${target}"
    local source
    for source in "${sources[@]}"; do
      if ! cp -a "${data_dir}/${source}" "${target}/${source}"; then
        log_error "Copying ${source} into ${target} failed; removing it."
        rm -rf "${target}"
        return 1
      fi
    done
    ;;
  *)
    log_error "Unknown BACKUP_MODE '${mode}'. Use 'tar' or 'dir'."
    return 1
    ;;
  esac

  printf '%s\n' "${target}"
}

# Removes the oldest pz-* entries until at most `keep` remain. Anything that is
# not one of our own backups is left alone.
backup_rotate() {
  local backup_dir="$1" keep="$2"
  local entries=() count remove i line

  while IFS= read -r line; do
    entries+=("${line}")
  done < <(find "${backup_dir}" -maxdepth 1 -name 'pz-*' -printf '%f\n' 2>/dev/null | sort)

  count="${#entries[@]}"
  if [ "${count}" -le "${keep}" ]; then
    return 0
  fi

  remove=$((count - keep))
  for ((i = 0; i < remove; i++)); do
    rm -rf "${backup_dir:?}/${entries[$i]}"
    log_info "Removed old backup ${entries[$i]}"
  done
}

# Sends a notification when NTFY_URL is configured. Never fails the caller: a
# backup that succeeded must not be reported as broken because a notification
# could not be delivered.
#
# Keep the title and message ASCII. HTTP header values are latin-1, so typographic
# characters either raise an encoding error in the client or arrive mangled.
backup_notify() {
  local status="$1" message="$2"
  if [ -z "${NTFY_URL:-}" ]; then
    return 0
  fi
  local priority="default"
  if [ "${status}" = "failure" ]; then
    priority="high"
  fi
  # The token expansion is intentionally unquoted so it disappears entirely when
  # NTFY_TOKEN is unset, rather than passing an empty argument.
  # shellcheck disable=SC2086
  curl -fsS --max-time 10 \
    -H "Title: Project Zomboid backup ${status}" \
    -H "Priority: ${priority}" \
    ${NTFY_TOKEN:+-H "Authorization: Bearer ${NTFY_TOKEN}"} \
    -d "${message}" \
    "${NTFY_URL}" >/dev/null 2>&1 ||
    log_warn "Could not send the ntfy notification"
  return 0
}
