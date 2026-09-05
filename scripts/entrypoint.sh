#!/usr/bin/env bash
# Container entrypoint for the Project Zomboid dedicated server.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/log.sh
source "${SCRIPT_DIR}/lib/log.sh"
# shellcheck source=lib/ini.sh
source "${SCRIPT_DIR}/lib/ini.sh"
# shellcheck source=lib/steam.sh
source "${SCRIPT_DIR}/lib/steam.sh"
# shellcheck source=lib/jvm.sh
source "${SCRIPT_DIR}/lib/jvm.sh"
# shellcheck source=lib/args.sh
source "${SCRIPT_DIR}/lib/args.sh"

PZ_SERVER_DIR="${PZ_SERVER_DIR:-/data/server}"
PZ_DATA_DIR="${PZ_DATA_DIR:-/data/zomboid}"
PZ_BRANCH="${PZ_BRANCH:-public}"
PZ_MAX_RAM="${PZ_MAX_RAM:-4g}"
UPDATE_ON_START="${UPDATE_ON_START:-true}"
SERVER_NAME="${SERVER_NAME:-servertest}"
SERVER_CONSOLE="${SERVER_CONSOLE:-/tmp/pz-console}"

SHUTDOWN_STARTED=""
SHUTDOWN_EXIT=0
SERVER_PID=""

preflight() {
  local dir
  for dir in "${PZ_SERVER_DIR}" "${PZ_DATA_DIR}"; do
    mkdir -p "${dir}" 2>/dev/null || true
    if [ ! -w "${dir}" ]; then
      log_error "${dir} is not writable by uid $(id -u). Bind mounts must be" \
        "owned by 1000:1000 - run: chown -R 1000:1000 <host directory>"
      return 1
    fi
  done
}

install_phase() {
  if [ "${PZ_SKIP_INSTALL:-false}" = "true" ]; then
    log_info "PZ_SKIP_INSTALL is set, skipping SteamCMD"
    return 0
  fi
  if ! steam_is_installed "${PZ_SERVER_DIR}"; then
    log_info "No installation found in ${PZ_SERVER_DIR}, installing now."
    log_info "The first start downloads roughly 3 GB and takes several minutes."
    steam_install "${PZ_SERVER_DIR}" "${PZ_BRANCH}"
  elif [ "${UPDATE_ON_START}" = "true" ]; then
    steam_install "${PZ_SERVER_DIR}" "${PZ_BRANCH}"
  else
    log_info "UPDATE_ON_START is false, keeping the installed version"
  fi
}

# Sets an INI key from an environment variable, skipping it when unset. An empty
# but defined variable is written, so a value can be cleared deliberately.
ini_set_from_env() {
  local ini="$1" key="$2" var="$3"
  if [ -z "${!var+defined}" ]; then
    return 0
  fi
  ini_set "${ini}" "${key}" "${!var}"
}

configure_phase() {
  if [ "${PZ_SKIP_INSTALL:-false}" = "true" ]; then
    return 0
  fi

  local ini="${PZ_DATA_DIR}/Server/${SERVER_NAME}.ini"
  # Pre-creating the file means values set here apply on the very first boot
  # instead of only after a restart.
  ini_ensure_file "${ini}"

  ini_set_from_env "${ini}" "Password" "SERVER_PASSWORD"
  ini_set_from_env "${ini}" "RCONPassword" "RCON_PASSWORD"
  ini_set_from_env "${ini}" "RCONPort" "RCON_PORT"
  ini_set_from_env "${ini}" "Public" "PUBLIC"
  ini_set_from_env "${ini}" "PublicName" "PUBLIC_NAME"
  ini_set_from_env "${ini}" "MaxPlayers" "MAX_PLAYERS"
  ini_set_from_env "${ini}" "DefaultPort" "GAME_PORT"
  ini_set_from_env "${ini}" "UDPPort" "UDP_PORT"

  if [ "${SELF_MANAGED_MODS:-false}" = "true" ]; then
    log_info "SELF_MANAGED_MODS is set, leaving Mods and WorkshopItems alone"
  else
    ini_set "${ini}" "Mods" "${MOD_IDS:-}"
    ini_set "${ini}" "WorkshopItems" "${WORKSHOP_IDS:-}"
    ini_check_mod_ids "${MOD_IDS:-}" "${PZ_BRANCH}"
  fi

  jvm_set_heap "${PZ_SERVER_DIR}/ProjectZomboid64.json" "${PZ_MAX_RAM}"
}

# Adapted from Danixu/project-zomboid-server-docker (scripts/entry.sh:325-377,
# GPL-3.0).
#
# Docker delivers SIGTERM to PID 1 only, and bash does not relay signals to its
# children, so the JVM would never learn that a shutdown is happening and would
# be SIGKILLed mid-world. The server reads console commands from stdin and its
# `quit` command saves the world and exits, so stdin is a FIFO this script holds
# open and the signal handler writes `quit` into it.
shutdown_server() {
  if [ -n "${SHUTDOWN_STARTED}" ]; then
    return 0
  fi
  SHUTDOWN_STARTED=1

  log_info "Shutdown requested, sending 'quit' to the server console"
  printf 'quit\n' >&"${CONSOLE_FD}"

  # `wait` returns 128+signal when it is itself interrupted, which is
  # indistinguishable by status alone from the server having been killed.
  # Retrying while the process is still alive is what stops an impatient second
  # signal from abandoning a save that is still running.
  while true; do
    SHUTDOWN_EXIT=0
    wait "${SERVER_PID}" || SHUTDOWN_EXIT=$?
    if [ "${SHUTDOWN_EXIT}" -le 128 ] || ! kill -0 "${SERVER_PID}" 2>/dev/null; then
      break
    fi
    log_info "Still saving, waiting for the server to finish"
  done
  log_info "Server stopped cleanly with exit code ${SHUTDOWN_EXIT}"
}

start_server() {
  if ! steam_is_installed "${PZ_SERVER_DIR}"; then
    log_error "No start-server.sh in ${PZ_SERVER_DIR}; the installation is" \
      "incomplete."
    return 1
  fi

  rm -f "${SERVER_CONSOLE}"
  mkfifo "${SERVER_CONSOLE}"
  # Held open read-write for the lifetime of this script. Without a writer the
  # server would read EOF immediately and stop accepting console commands.
  exec {CONSOLE_FD}<>"${SERVER_CONSOLE}"

  local first_boot="false"
  if args_is_first_boot "${PZ_DATA_DIR}" "${SERVER_NAME}"; then
    first_boot="true"
    log_info "No world database found, treating this as the first boot"
  fi
  args_build "${PZ_DATA_DIR}" "${SERVER_NAME}" "${first_boot}"

  # Works around a bug in start-server.sh that fails to preload libjsig.so.
  export LD_LIBRARY_PATH="${PZ_SERVER_DIR}/jre64/lib:${LD_LIBRARY_PATH:-}"

  cd "${PZ_SERVER_DIR}"
  ./start-server.sh "${PZ_ARGS[@]}" <"${SERVER_CONSOLE}" &
  SERVER_PID=$!

  # Installed only once the PID is known, so the handler can never reference an
  # unset variable.
  trap shutdown_server TERM INT

  local exit_code=0
  wait "${SERVER_PID}" || exit_code=$?
  if [ -n "${SHUTDOWN_STARTED}" ]; then
    exit_code="${SHUTDOWN_EXIT}"
  fi

  rm -f "${SERVER_CONSOLE}"
  return "${exit_code}"
}

main() {
  preflight
  install_phase
  configure_phase
  start_server
}

main "$@"
