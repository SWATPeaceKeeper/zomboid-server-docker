#!/usr/bin/env bats

load '../helpers/load'

setup() {
  setup_tmpdir
  SERVER_DIR="${TEST_TMP}/server"
  DATA_DIR="${TEST_TMP}/zomboid"
  mkdir -p "${SERVER_DIR}" "${DATA_DIR}"

  # A stand-in for start-server.sh: it reports readiness, echoes whatever it is
  # told on stdin, and exits 0 when it receives `quit` - the same contract the
  # real server has.
  cat >"${SERVER_DIR}/start-server.sh" <<EOF
#!/usr/bin/env bash
echo "SERVER STARTED"
printf '%s\n' "\$@" >"${TEST_TMP}/server-args.log"
while IFS= read -r cmd; do
  echo "console: \$cmd"
  if [ "\$cmd" = "quit" ]; then
    echo "saved" >"${TEST_TMP}/saved.marker"
    exit 0
  fi
done
exit 7
EOF
  chmod +x "${SERVER_DIR}/start-server.sh"

  export PZ_SKIP_INSTALL=true
  export PZ_SERVER_DIR="${SERVER_DIR}"
  export PZ_DATA_DIR="${DATA_DIR}"
  export SERVER_CONSOLE="${TEST_TMP}/pz-console"
}

teardown() {
  teardown_tmpdir
}

# Starts the entrypoint in the background and waits until the stand-in server
# has announced readiness. The PID goes into ENTRY_PID rather than being printed:
# a command substitution would run this in a subshell, making the entrypoint a
# child of that subshell, and `wait` in the test would then return immediately
# instead of blocking until the shutdown really finished.
#
# fd 3 is closed explicitly. bats keeps its own output on fd 3 and waits for
# every copy of it to close, so a background process that inherits it hangs the
# whole run.
start_entrypoint() {
  # Job control matters here. Bash gives asynchronous commands SIGINT set to
  # ignore, and a signal that was ignored on entry cannot be trapped afterwards,
  # so `trap ... INT` inside the entrypoint would silently do nothing and the
  # SIGINT test would hang forever. With monitor mode the background job gets its
  # own process group and the default disposition, which is what PID 1 in a
  # container has.
  set -m
  "${REPO_ROOT}/scripts/entrypoint.sh" >"${TEST_TMP}/out.log" 2>&1 3>&- &
  ENTRY_PID=$!
  set +m
  local waited=0
  while ! grep -q "SERVER STARTED" "${TEST_TMP}/out.log" 2>/dev/null; do
    sleep 0.1
    waited=$((waited + 1))
    if [ "${waited}" -ge 100 ]; then
      echo "entrypoint never became ready" >&2
      cat "${TEST_TMP}/out.log" >&2
      return 1
    fi
  done
}

# Waits for the entrypoint to exit, but kills it after `limit` seconds. Without
# this a shutdown path that never sends `quit` would block the whole test run
# instead of failing, which in CI means burning the job timeout on one bug.
wait_for_exit() {
  local pid="$1" limit="${2:-15}" status=0 watchdog
  (
    sleep "${limit}"
    kill -KILL "${pid}" 2>/dev/null
  ) 3>&- &
  watchdog=$!

  wait "${pid}" || status=$?

  kill "${watchdog}" 2>/dev/null || true
  wait "${watchdog}" 2>/dev/null || true
  return "${status}"
}

@test "entrypoint sends quit on SIGTERM and waits for the save" {
  start_entrypoint

  kill -TERM "${ENTRY_PID}"
  local status=0
  wait_for_exit "${ENTRY_PID}" || status=$?

  [ -f "${TEST_TMP}/saved.marker" ]
  [ "${status}" -eq 0 ]
  grep -q "console: quit" "${TEST_TMP}/out.log"
}

@test "entrypoint reports the clean stop in its log" {
  start_entrypoint
  kill -TERM "${ENTRY_PID}"
  wait_for_exit "${ENTRY_PID}" || true
  grep -q "Server stopped cleanly" "${TEST_TMP}/out.log"
}

@test "entrypoint handles SIGINT the same way" {
  start_entrypoint
  kill -INT "${ENTRY_PID}"
  wait_for_exit "${ENTRY_PID}" || true
  [ -f "${TEST_TMP}/saved.marker" ]
}

@test "entrypoint passes cachedir and servername to the server" {
  SERVER_NAME="My World"
  export SERVER_NAME
  start_entrypoint
  kill -TERM "${ENTRY_PID}"
  wait_for_exit "${ENTRY_PID}" || true

  grep -q -- "^-cachedir=${DATA_DIR}$" "${TEST_TMP}/server-args.log"
  grep -q '^My World$' "${TEST_TMP}/server-args.log"
}

@test "entrypoint fails when the server is not installed" {
  rm -f "${SERVER_DIR}/start-server.sh"
  run "${REPO_ROOT}/scripts/entrypoint.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"installation"* ]]
}

@test "entrypoint fails fast when the data directory is not writable" {
  if [ "$(id -u)" -eq 0 ]; then
    skip "permission checks are meaningless as root"
  fi
  chmod 500 "${DATA_DIR}"
  run "${REPO_ROOT}/scripts/entrypoint.sh"
  chmod 700 "${DATA_DIR}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not writable"* ]]
}
