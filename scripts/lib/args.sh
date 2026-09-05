#!/usr/bin/env bash
# Construction of the server command line.
#
# Every value goes into an array element of its own, so names and passwords
# containing spaces reach the server as a single argument.

args_is_first_boot() {
  local data_dir="$1" server_name="$2"
  [ ! -f "${data_dir}/db/${server_name}.db" ]
}

args_build() {
  local data_dir="$1" server_name="$2" first_boot="$3"

  PZ_ARGS=()
  PZ_ARGS+=("-cachedir=${data_dir}")
  PZ_ARGS+=("-servername" "${server_name}")

  # The server writes its full command line into the log on every start, so the
  # admin password is only passed when it is actually needed: on the very first
  # boot, when the account does not exist yet. Afterwards it lives in the world
  # database and re-passing it would leak it into every log file.
  if [ "${first_boot}" = "true" ]; then
    if [ -n "${ADMIN_USERNAME:-}" ]; then
      PZ_ARGS+=("-adminusername" "${ADMIN_USERNAME}")
    fi
    if [ -n "${ADMIN_PASSWORD:-}" ]; then
      PZ_ARGS+=("-adminpassword" "${ADMIN_PASSWORD}")
    fi
  fi

  # Disables Steam integration. Note that this also disables Workshop downloads.
  if [ "${NOSTEAM:-false}" = "true" ]; then
    PZ_ARGS+=("-nosteam")
  fi

  if [ -n "${MODFOLDERS:-}" ]; then
    PZ_ARGS+=("-modfolders" "${MODFOLDERS}")
  fi

  return 0
}
