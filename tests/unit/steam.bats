#!/usr/bin/env bats

load '../helpers/load'

setup() {
  setup_tmpdir
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/scripts/lib/log.sh"
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/scripts/lib/steam.sh"
  INSTALL_DIR="${TEST_TMP}/server"
  ARG_LOG="${TEST_TMP}/steamcmd-args.log"
  ATTEMPT_FILE="${TEST_TMP}/attempts"
  STEAM_RETRY_DELAY=0
  export STEAM_RETRY_DELAY
}

teardown() {
  teardown_tmpdir
}

# Writes a stub steamcmd that records its arguments and exits with $1.
make_stub() {
  local exit_code="$1"
  STEAMCMD_BIN="${TEST_TMP}/steamcmd-stub"
  cat >"${STEAMCMD_BIN}" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"${ARG_LOG}"
echo x >>"${ATTEMPT_FILE}"
exit ${exit_code}
EOF
  chmod +x "${STEAMCMD_BIN}"
  export STEAMCMD_BIN
}

@test "steam_branch_args is empty for the public branch" {
  steam_branch_args "public"
  [ "${#STEAM_BRANCH_ARGS[@]}" -eq 0 ]
}

@test "steam_branch_args is empty for an unset branch" {
  steam_branch_args ""
  [ "${#STEAM_BRANCH_ARGS[@]}" -eq 0 ]
}

@test "steam_branch_args passes -beta for a named branch" {
  steam_branch_args "legacy41"
  [ "${STEAM_BRANCH_ARGS[0]}" = "-beta" ]
  [ "${STEAM_BRANCH_ARGS[1]}" = "legacy41" ]
}

@test "steam_install never passes -beta public" {
  make_stub 0
  run steam_install "${INSTALL_DIR}" "public"
  [ "$status" -eq 0 ]
  run grep -c -- '-beta' "${ARG_LOG}"
  [ "$output" = "0" ]
}

@test "steam_install passes -beta for the legacy41 branch" {
  make_stub 0
  steam_install "${INSTALL_DIR}" "legacy41"
  grep -q -- '^-beta$' "${ARG_LOG}"
  grep -q '^legacy41$' "${ARG_LOG}"
}

@test "steam_install passes the app id and validate" {
  make_stub 0
  steam_install "${INSTALL_DIR}" "public"
  grep -q '^380870$' "${ARG_LOG}"
  grep -q '^validate$' "${ARG_LOG}"
}

@test "steam_install logs in anonymously" {
  make_stub 0
  steam_install "${INSTALL_DIR}" "public"
  grep -q '^anonymous$' "${ARG_LOG}"
}

@test "steam_install retries and gives up after STEAM_RETRIES attempts" {
  make_stub 1
  STEAM_RETRIES=3
  export STEAM_RETRIES
  run steam_install "${INSTALL_DIR}" "public"
  [ "$status" -eq 1 ]
  run wc -l <"${ATTEMPT_FILE}"
  [ "${output// /}" = "3" ]
}

@test "steam_install stops retrying once an attempt succeeds" {
  # Fails once, then succeeds: the loop must not run a third time.
  STEAMCMD_BIN="${TEST_TMP}/steamcmd-flaky"
  cat >"${STEAMCMD_BIN}" <<EOF
#!/usr/bin/env bash
echo x >>"${ATTEMPT_FILE}"
if [ "\$(wc -l <"${ATTEMPT_FILE}")" -lt 2 ]; then
  exit 1
fi
exit 0
EOF
  chmod +x "${STEAMCMD_BIN}"
  export STEAMCMD_BIN

  STEAM_RETRIES=5
  export STEAM_RETRIES
  run steam_install "${INSTALL_DIR}" "public"
  [ "$status" -eq 0 ]
  run wc -l <"${ATTEMPT_FILE}"
  [ "${output// /}" = "2" ]
}

@test "steam_is_installed detects the start script" {
  run steam_is_installed "${INSTALL_DIR}"
  [ "$status" -ne 0 ]
  mkdir -p "${INSTALL_DIR}"
  touch "${INSTALL_DIR}/start-server.sh"
  run steam_is_installed "${INSTALL_DIR}"
  [ "$status" -eq 0 ]
}
