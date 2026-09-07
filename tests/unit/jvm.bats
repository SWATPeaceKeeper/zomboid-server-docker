#!/usr/bin/env bats

load '../helpers/load'

setup() {
  setup_tmpdir
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/scripts/lib/log.sh"
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/scripts/lib/jvm.sh"
  JSON="${TEST_TMP}/ProjectZomboid64.json"
  JMX_JAR="${TEST_TMP}/jmx.jar"
  : >"${JMX_JAR}"
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

@test "jvm_set_jmx_agent adds the agent argument" {
  jvm_set_jmx_agent "${JSON}" "${JMX_JAR}" "9404"
  run jq -r '.vmArgs | map(select(startswith("-javaagent"))) | length' "${JSON}"
  [ "$output" = "1" ]
  run jq -r '.vmArgs | map(select(startswith("-javaagent"))) | join("")' "${JSON}"
  [[ "$output" == *"${JMX_JAR}=9404"* ]]
}

@test "jvm_set_jmx_agent is idempotent" {
  jvm_set_jmx_agent "${JSON}" "${JMX_JAR}" "9404"
  jvm_set_jmx_agent "${JSON}" "${JMX_JAR}" "9404"
  run jq -r '.vmArgs | map(select(startswith("-javaagent"))) | length' "${JSON}"
  [ "$output" = "1" ]
}

@test "jvm_set_jmx_agent keeps the heap flags" {
  jvm_set_heap "${JSON}" "4g"
  jvm_set_jmx_agent "${JSON}" "${JMX_JAR}" "9404"
  run jq -r '.vmArgs | map(select(startswith("-Xmx"))) | join("")' "${JSON}"
  [ "$output" = "-Xmx4g" ]
}

@test "jvm_set_heap does not remove an existing agent" {
  jvm_set_jmx_agent "${JSON}" "${JMX_JAR}" "9404"
  jvm_set_heap "${JSON}" "4g"
  run jq -r '.vmArgs | map(select(startswith("-javaagent"))) | length' "${JSON}"
  [ "$output" = "1" ]
}

@test "jvm_set_jmx_agent fails when the jar is not in the image" {
  run jvm_set_jmx_agent "${JSON}" "${TEST_TMP}/absent.jar" "9404"
  [ "$status" -ne 0 ]
}

@test "jvm_size_to_bytes understands the JVM size suffixes" {
  run jvm_size_to_bytes "4g"
  [ "$output" = "4294967296" ]
  run jvm_size_to_bytes "512m"
  [ "$output" = "536870912" ]
  run jvm_size_to_bytes "2048k"
  [ "$output" = "2097152" ]
  run jvm_size_to_bytes "1024"
  [ "$output" = "1024" ]
}

@test "jvm_size_to_bytes rejects anything else" {
  run jvm_size_to_bytes "lots"
  [ "$status" -eq 1 ]
  run jvm_size_to_bytes "4gb"
  [ "$status" -eq 1 ]
  run jvm_size_to_bytes ""
  [ "$status" -eq 1 ]
}

@test "jvm_check_memory_limit passes when there is no limit at all" {
  run jvm_check_memory_limit "64g" ""
  [ "$status" -eq 0 ]
}

@test "jvm_check_memory_limit passes when the limit holds heap plus headroom" {
  # 4 GiB heap plus the 3 GiB Build 42 needs outside it.
  run jvm_check_memory_limit "4g" "$((7 * 1024 * 1024 * 1024))"
  [ "$status" -eq 0 ]
}

@test "jvm_check_memory_limit fails when the limit cannot hold the heap" {
  run jvm_check_memory_limit "8g" "$((7 * 1024 * 1024 * 1024))"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PZ_MEM_LIMIT"* ]]
  [[ "$output" == *"11"* ]]
}

@test "jvm_check_memory_limit fails on a PZ_MAX_RAM it cannot read" {
  run jvm_check_memory_limit "plenty" "$((7 * 1024 * 1024 * 1024))"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PZ_MAX_RAM"* ]]
}

# The suite runs inside a container and cannot choose its own cgroup, so this
# checks the contract rather than a value: either a plain byte count or nothing
# at all, never "max" and never a v1 placeholder the size of a galaxy.
@test "jvm_container_memory_limit reports a byte count or nothing" {
  run jvm_container_memory_limit
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]*$ ]]
}
