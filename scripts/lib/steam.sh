#!/usr/bin/env bash
# Installing and updating the Project Zomboid dedicated server through SteamCMD.

PZ_APP_ID="${PZ_APP_ID:-380870}"

# Builds the beta arguments for a branch into the STEAM_BRANCH_ARGS array.
#
# `public` is not a beta. Passing `-beta public` makes SteamCMD look for a beta
# that does not exist; the update then silently does nothing and the server keeps
# running whatever version is already on disk.
steam_branch_args() {
  local branch="${1:-public}"
  STEAM_BRANCH_ARGS=()
  if [ -n "${branch}" ] && [ "${branch}" != "public" ]; then
    STEAM_BRANCH_ARGS=(-beta "${branch}")
  fi
}

steam_is_installed() {
  local install_dir="$1"
  [ -f "${install_dir}/start-server.sh" ]
}

# Installs or updates the server. Steam downloads fail intermittently, so this
# retries rather than leaving the container in a half-installed state.
steam_install() {
  local install_dir="$1" branch="$2"
  local steamcmd="${STEAMCMD_BIN:-/usr/games/steamcmd}"
  local retries="${STEAM_RETRIES:-3}"
  local delay="${STEAM_RETRY_DELAY:-15}"
  local attempt=1

  steam_branch_args "${branch}"
  mkdir -p "${install_dir}"

  while [ "${attempt}" -le "${retries}" ]; do
    log_info "SteamCMD attempt ${attempt}/${retries} for branch '${branch}'"
    if "${steamcmd}" \
      +force_install_dir "${install_dir}" \
      +login anonymous \
      +app_update "${PZ_APP_ID}" "${STEAM_BRANCH_ARGS[@]}" validate \
      +quit; then
      log_info "SteamCMD finished successfully"
      return 0
    fi
    log_warn "SteamCMD attempt ${attempt} failed"
    attempt=$((attempt + 1))
    if [ "${attempt}" -le "${retries}" ]; then
      sleep "${delay}"
    fi
  done

  log_error "SteamCMD failed after ${retries} attempts. Check network access to" \
    "the Steam content servers and that ${install_dir} is writable."
  return 1
}
