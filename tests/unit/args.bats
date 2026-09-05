#!/usr/bin/env bats

load '../helpers/load'

setup() {
  setup_tmpdir
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/scripts/lib/log.sh"
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/scripts/lib/args.sh"
  DATA_DIR="${TEST_TMP}/zomboid"
  mkdir -p "${DATA_DIR}"
  unset ADMIN_USERNAME ADMIN_PASSWORD NOSTEAM MODFOLDERS
}

teardown() {
  teardown_tmpdir
}

# Prints one PZ_ARGS element per line, for exact matching.
args_lines() {
  printf '%s\n' "${PZ_ARGS[@]}"
}

@test "args_is_first_boot is true when the world database is absent" {
  run args_is_first_boot "${DATA_DIR}" "servertest"
  [ "$status" -eq 0 ]
}

@test "args_is_first_boot is false once the world database exists" {
  mkdir -p "${DATA_DIR}/db"
  touch "${DATA_DIR}/db/servertest.db"
  run args_is_first_boot "${DATA_DIR}" "servertest"
  [ "$status" -ne 0 ]
}

@test "args_is_first_boot looks at the matching server name only" {
  mkdir -p "${DATA_DIR}/db"
  touch "${DATA_DIR}/db/otherworld.db"
  run args_is_first_boot "${DATA_DIR}" "servertest"
  [ "$status" -eq 0 ]
}

@test "args_build sets cachedir and servername" {
  args_build "${DATA_DIR}" "servertest" "false"
  run args_lines
  [[ "$output" == *"-cachedir=${DATA_DIR}"* ]]
  [[ "$output" == *"-servername"* ]]
  [[ "$output" == *"servertest"* ]]
}

@test "args_build keeps a server name containing spaces as one element" {
  args_build "${DATA_DIR}" "My World" "false"
  local found=0 i
  for i in "${!PZ_ARGS[@]}"; do
    if [ "${PZ_ARGS[$i]}" = "My World" ]; then found=1; fi
  done
  [ "$found" -eq 1 ]
}

@test "args_build keeps an admin password containing spaces as one element" {
  ADMIN_PASSWORD="two words"
  export ADMIN_PASSWORD
  args_build "${DATA_DIR}" "servertest" "true"
  local found=0 i
  for i in "${!PZ_ARGS[@]}"; do
    if [ "${PZ_ARGS[$i]}" = "two words" ]; then found=1; fi
  done
  [ "$found" -eq 1 ]
}

@test "args_build emits the admin password only on first boot" {
  ADMIN_USERNAME="admin"
  ADMIN_PASSWORD="s3cret"
  export ADMIN_USERNAME ADMIN_PASSWORD

  args_build "${DATA_DIR}" "servertest" "true"
  run args_lines
  [[ "$output" == *"-adminpassword"* ]]

  args_build "${DATA_DIR}" "servertest" "false"
  run args_lines
  [[ "$output" != *"-adminpassword"* ]]
  [[ "$output" != *"s3cret"* ]]
}

@test "args_build never emits heap flags" {
  args_build "${DATA_DIR}" "servertest" "false"
  run args_lines
  [[ "$output" != *"-Xmx"* ]]
  [[ "$output" != *"-Xms"* ]]
}

@test "args_build adds -nosteam only when requested" {
  args_build "${DATA_DIR}" "servertest" "false"
  run args_lines
  [[ "$output" != *"-nosteam"* ]]

  NOSTEAM="true"
  export NOSTEAM
  args_build "${DATA_DIR}" "servertest" "false"
  run args_lines
  [[ "$output" == *"-nosteam"* ]]
}

@test "args_build passes modfolders when set" {
  MODFOLDERS="mods,workshop"
  export MODFOLDERS
  args_build "${DATA_DIR}" "servertest" "false"
  run args_lines
  [[ "$output" == *"-modfolders"* ]]
  [[ "$output" == *"mods,workshop"* ]]
}

@test "args_build succeeds under set -e with everything unset" {
  set -e
  args_build "${DATA_DIR}" "servertest" "false"
  [ "${#PZ_ARGS[@]}" -gt 0 ]
}
