#!/usr/bin/env bats

load '../helpers/load'

setup() {
  setup_tmpdir
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/scripts/lib/log.sh"
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/scripts/backup/lib/backup.sh"
  DATA_DIR="${TEST_TMP}/zomboid"
  BACKUP_DIR="${TEST_TMP}/backups"
  mkdir -p "${DATA_DIR}/Saves/Multiplayer/servertest" "${DATA_DIR}/Server" "${BACKUP_DIR}"
  echo "world data" >"${DATA_DIR}/Saves/Multiplayer/servertest/map.bin"
  echo "Public=false" >"${DATA_DIR}/Server/servertest.ini"
  unset NTFY_URL
}

teardown() {
  teardown_tmpdir
}

@test "backup_duration_to_seconds understands the supported units" {
  run backup_duration_to_seconds "90"
  [ "$output" = "90" ]
  run backup_duration_to_seconds "30s"
  [ "$output" = "30" ]
  run backup_duration_to_seconds "15m"
  [ "$output" = "900" ]
  run backup_duration_to_seconds "6h"
  [ "$output" = "21600" ]
  run backup_duration_to_seconds "1d"
  [ "$output" = "86400" ]
}

@test "backup_duration_to_seconds rejects nonsense" {
  run backup_duration_to_seconds "soon"
  [ "$status" -eq 1 ]
  run backup_duration_to_seconds "6y"
  [ "$status" -eq 1 ]
  run backup_duration_to_seconds ""
  [ "$status" -eq 1 ]
}

@test "backup_create writes a tar archive in tar mode" {
  run backup_create "${DATA_DIR}" "${BACKUP_DIR}" "tar"
  [ "$status" -eq 0 ]
  [ -f "$output" ]
  [[ "$output" == *.tar.zst ]]
}

@test "backup_create tar archive contains the world and the config" {
  local archive
  archive="$(backup_create "${DATA_DIR}" "${BACKUP_DIR}" "tar")"
  run tar --use-compress-program=zstd -tf "${archive}"
  [[ "$output" == *"Saves/Multiplayer/servertest/map.bin"* ]]
  [[ "$output" == *"Server/servertest.ini"* ]]
}

@test "backup_create writes a directory copy in dir mode" {
  run backup_create "${DATA_DIR}" "${BACKUP_DIR}" "dir"
  [ "$status" -eq 0 ]
  [ -d "$output" ]
  [ -f "${output}/Saves/Multiplayer/servertest/map.bin" ]
  [ -f "${output}/Server/servertest.ini" ]
}

@test "backup_create fails on an unknown mode" {
  run backup_create "${DATA_DIR}" "${BACKUP_DIR}" "magnetic-tape"
  [ "$status" -ne 0 ]
}

@test "backup_create fails when the source has no Saves directory" {
  rm -rf "${DATA_DIR}/Saves"
  run backup_create "${DATA_DIR}" "${BACKUP_DIR}" "tar"
  [ "$status" -ne 0 ]
}

@test "backup_create works when there is no Server directory yet" {
  rm -rf "${DATA_DIR}/Server"
  run backup_create "${DATA_DIR}" "${BACKUP_DIR}" "tar"
  [ "$status" -eq 0 ]
  [ -f "$output" ]
}

@test "backup_create reports failure when the archiver fails" {
  # A backup tool that prints a path for an archive that was never written hides
  # the failure until the backup is actually needed.
  mkdir -p "${TEST_TMP}/bin"
  printf '#!/usr/bin/env bash\nexit 2\n' >"${TEST_TMP}/bin/tar"
  chmod +x "${TEST_TMP}/bin/tar"
  PATH="${TEST_TMP}/bin:${PATH}"

  run backup_create "${DATA_DIR}" "${BACKUP_DIR}" "tar"
  [ "$status" -ne 0 ]
  run bash -c "ls '${BACKUP_DIR}' | wc -l"
  [ "${output// /}" = "0" ]
}

@test "backup_rotate keeps the requested number of newest backups" {
  local i
  for i in 1 2 3 4 5; do
    touch "${BACKUP_DIR}/pz-2026010${i}-000000.tar.zst"
  done
  backup_rotate "${BACKUP_DIR}" 2
  run bash -c "ls '${BACKUP_DIR}' | wc -l"
  [ "${output// /}" = "2" ]
  [ -f "${BACKUP_DIR}/pz-20260105-000000.tar.zst" ]
  [ ! -f "${BACKUP_DIR}/pz-20260101-000000.tar.zst" ]
}

@test "backup_rotate removes directory backups too" {
  local i
  for i in 1 2 3; do
    mkdir -p "${BACKUP_DIR}/pz-2026010${i}-000000"
  done
  backup_rotate "${BACKUP_DIR}" 1
  [ -d "${BACKUP_DIR}/pz-20260103-000000" ]
  [ ! -d "${BACKUP_DIR}/pz-20260101-000000" ]
}

@test "backup_rotate leaves unrelated files alone" {
  touch "${BACKUP_DIR}/pz-20260101-000000.tar.zst"
  touch "${BACKUP_DIR}/README.txt"
  backup_rotate "${BACKUP_DIR}" 0
  [ -f "${BACKUP_DIR}/README.txt" ]
  [ ! -f "${BACKUP_DIR}/pz-20260101-000000.tar.zst" ]
}

@test "backup_rotate does nothing when below the limit" {
  touch "${BACKUP_DIR}/pz-20260101-000000.tar.zst"
  backup_rotate "${BACKUP_DIR}" 5
  [ -f "${BACKUP_DIR}/pz-20260101-000000.tar.zst" ]
}

@test "backup-now works when invoked through a symlink" {
  # The image exposes it as /usr/local/bin/backup-now. Without resolving the
  # symlink, BASH_SOURCE points at the link and the library paths resolve into a
  # directory that does not exist, so the documented invocation is broken.
  ln -s "${REPO_ROOT}/scripts/backup/backup-now.sh" "${TEST_TMP}/backup-now"

  PZ_DATA_DIR="${DATA_DIR}" \
    BACKUP_DIR="${BACKUP_DIR}" \
    BACKUP_MODE="tar" \
    run "${TEST_TMP}/backup-now"

  [ "$status" -eq 0 ]
  [[ "$output" != *"No such file"* ]]
  run bash -c "ls '${BACKUP_DIR}'/pz-*.tar.zst | wc -l"
  [ "${output// /}" = "1" ]
}

@test "backup_notify is a no-op without NTFY_URL" {
  run backup_notify "failure" "something broke"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "backup_notify never fails the caller when the endpoint is unreachable" {
  NTFY_URL="http://127.0.0.1:1/topic"
  export NTFY_URL
  run backup_notify "failure" "something broke"
  [ "$status" -eq 0 ]
}
