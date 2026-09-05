#!/usr/bin/env bats

load '../helpers/load'

setup() {
  setup_tmpdir
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/scripts/lib/log.sh"
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/scripts/lib/jvm.sh"
  JSON="${TEST_TMP}/ProjectZomboid64.json"
  cat >"${JSON}" <<'EOF'
{
  "mainClass": "zombie/network/GameServer",
  "classpath": ["java/.", "java/lwjgl.jar"],
  "vmArgs": [
    "-Djava.awt.headless=true",
    "-Xms512m",
    "-Xmx512m",
    "-XX:-OmitStackTraceInFastThrow"
  ]
}
EOF
}

teardown() {
  teardown_tmpdir
}

@test "jvm_set_heap replaces the existing heap flags" {
  jvm_set_heap "${JSON}" "4g"
  run jq -r '.vmArgs | map(select(startswith("-Xmx"))) | join(",")' "${JSON}"
  [ "$output" = "-Xmx4g" ]
  run jq -r '.vmArgs | map(select(startswith("-Xms"))) | join(",")' "${JSON}"
  [ "$output" = "-Xms4g" ]
}

@test "jvm_set_heap keeps unrelated vmArgs" {
  jvm_set_heap "${JSON}" "4g"
  run jq -r '.vmArgs | index("-Djava.awt.headless=true")' "${JSON}"
  [ "$output" != "null" ]
  run jq -r '.vmArgs | index("-XX:-OmitStackTraceInFastThrow")' "${JSON}"
  [ "$output" != "null" ]
}

@test "jvm_set_heap keeps other top-level keys" {
  jvm_set_heap "${JSON}" "4g"
  run jq -r '.mainClass' "${JSON}"
  [ "$output" = "zombie/network/GameServer" ]
  run jq -r '.classpath | length' "${JSON}"
  [ "$output" = "2" ]
}

@test "jvm_set_heap adds the flags when vmArgs has none" {
  jq 'del(.vmArgs)' "${JSON}" >"${JSON}.tmp" && mv "${JSON}.tmp" "${JSON}"
  jvm_set_heap "${JSON}" "8g"
  run jq -r '.vmArgs | length' "${JSON}"
  [ "$output" = "2" ]
}

@test "jvm_set_heap is idempotent" {
  jvm_set_heap "${JSON}" "4g"
  jvm_set_heap "${JSON}" "4g"
  run jq -r '.vmArgs | map(select(startswith("-Xmx"))) | length' "${JSON}"
  [ "$output" = "1" ]
}

@test "jvm_set_heap keeps the file valid json" {
  jvm_set_heap "${JSON}" "4g"
  run jq -e . "${JSON}"
  [ "$status" -eq 0 ]
}

@test "jvm_set_heap fails on a missing file" {
  run jvm_set_heap "${TEST_TMP}/absent.json" "4g"
  [ "$status" -eq 1 ]
}
