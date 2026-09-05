#!/usr/bin/env bats

load '../helpers/load'

setup() {
  setup_tmpdir
  export RCON_BIN="${TEST_TMP}/rcon-stub"
  export RCON_PORT="27015"
}

teardown() {
  teardown_tmpdir
}

# Writes a stub rcon client that records its arguments and exits with $1.
make_rcon_stub() {
  cat >"${RCON_BIN}" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >"${TEST_TMP}/rcon-args.log"
exit $1
EOF
  chmod +x "${RCON_BIN}"
}

@test "healthcheck succeeds when RCON answers" {
  make_rcon_stub 0
  RCON_PASSWORD="pw" run "${REPO_ROOT}/scripts/healthcheck.sh"
  [ "$status" -eq 0 ]
}

@test "healthcheck fails when RCON refuses" {
  make_rcon_stub 1
  RCON_PASSWORD="pw" run "${REPO_ROOT}/scripts/healthcheck.sh"
  [ "$status" -ne 0 ]
}

@test "healthcheck queries the players command" {
  make_rcon_stub 0
  RCON_PASSWORD="pw" run "${REPO_ROOT}/scripts/healthcheck.sh"
  grep -q '^players$' "${TEST_TMP}/rcon-args.log"
}

@test "healthcheck talks to the configured port" {
  make_rcon_stub 0
  RCON_PORT="27099" RCON_PASSWORD="pw" run "${REPO_ROOT}/scripts/healthcheck.sh"
  grep -q '^127.0.0.1:27099$' "${TEST_TMP}/rcon-args.log"
}

@test "healthcheck never puts the password in its own output" {
  make_rcon_stub 1
  RCON_PASSWORD="topsecret" run "${REPO_ROOT}/scripts/healthcheck.sh"
  [[ "$output" != *"topsecret"* ]]
}

@test "healthcheck falls back to a process check without a password" {
  unset RCON_PASSWORD
  run "${REPO_ROOT}/scripts/healthcheck.sh"
  # No server process runs in the test container, so this must fail rather than
  # report a healthy server.
  [ "$status" -ne 0 ]
  [[ "$output" == *"ProjectZomboid"* ]]
}
