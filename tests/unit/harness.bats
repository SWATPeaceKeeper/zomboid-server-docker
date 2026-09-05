#!/usr/bin/env bats

load '../helpers/load'

setup() {
  setup_tmpdir
}

teardown() {
  teardown_tmpdir
}

@test "harness: repository is mounted and readable" {
  [ -f "${REPO_ROOT}/tests/run-unit.sh" ]
}

@test "harness: temporary directory is writable" {
  echo "content" >"${TEST_TMP}/file"
  run cat "${TEST_TMP}/file"
  [ "$status" -eq 0 ]
  [ "$output" = "content" ]
}
