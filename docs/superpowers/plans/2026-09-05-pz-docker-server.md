# Project Zomboid Dedicated Server Image — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a container image and Compose stack that runs a Project Zomboid dedicated server with runtime-switchable game branch, environment-driven configuration, scheduled world backups, and a CI pipeline that actually starts the server before publishing.

**Architecture:** A slim SteamCMD-based image installs Steam app `380870` into a persistent volume at first start rather than baking it into the image. The entrypoint patches only operational keys into the server INI, sets the JVM heap in `ProjectZomboid64.json`, and runs the server with its stdin attached to a FIFO so `SIGTERM` can send the `quit` console command and wait for the world to be written. A separate sidecar container takes scheduled backups over RCON, which is reachable only on an internal Docker network.

**Tech Stack:** Bash, Docker + Compose v2, `steamcmd/steamcmd:ubuntu-24`, `gorcon/rcon-cli`, `bats-core` (via container), shellcheck/shfmt/hadolint/yamllint/zizmor/Trivy, GitHub Actions, GHCR, Renovate.

**Spec:** `docs/superpowers/specs/2026-09-05-pz-docker-server-design.md`

## Global Constraints

- **License:** GPL-3.0-or-later. Code adapted from `Danixu/project-zomboid-server-docker` must carry an attribution comment naming the upstream file and lines.
- **Base image, pinned by digest:** `steamcmd/steamcmd:ubuntu-24@sha256:2fbec2969d6caf1d203b62a365c0198c17c7eb9859b39f715c8acabfe917c182`
- **UID/GID 1000 is occupied** by the `ubuntu` user in the Ubuntu 24.04 base image. It must be removed before creating the `pz` user, or `useradd -u 1000` fails.
- **rcon-cli:** v0.10.3, `rcon-0.10.3-amd64_linux.tar.gz`, SHA-256 `6962a641ebf9a5957bd0cda1b8acf3e34a23686ae709f6c6a14ac3898521a5cc`, binary at `rcon-0.10.3-amd64_linux/rcon` inside the archive.
- **Every shell script** starts with `#!/usr/bin/env bash` and `set -euo pipefail`, passes `shellcheck` with zero warnings, and is formatted with `shfmt -i 2`.
- **Bash style:** never use `[ cond ] && action` as the final statement of a function — under `set -e` a false condition makes the function return non-zero. Use `if` blocks.
- **Function limits:** ≤100 lines, cyclomatic complexity ≤8, ≤5 positional parameters, 100-character lines.
- **No secrets in the repository.** Compose uses required-variable syntax (`${PZ_ADMIN_PASSWORD:?set this in .env}`). Never create or edit `.env` files — the harness blocks it; document the variables instead.
- **RCON port `27015` is never published to the host.** Server and sidecar communicate over the internal `pz-internal` network.
- **GitHub Actions are pinned to commit SHAs** with a version comment and use `persist-credentials: false`.
- **Documentation is written in English** (public repository). Use proper Unicode characters throughout.
- **Defaults:** `PZ_BRANCH=public` (Build 42), `PZ_MAX_RAM=4g`, `UPDATE_ON_START=true`, `BACKUP_INTERVAL=6h`, `BACKUP_KEEP=14`, `BACKUP_MODE=tar`, `BACKUP_ON_START=true`.
- **Deviation from the spec, intentional:** the spec listed `scripts/lib/{steam.sh,ini.sh,args.sh}`. JVM heap handling gets its own `scripts/lib/jvm.sh` because it edits JSON with `jq` and shares nothing with command-line argument construction.
- **Deviation from the spec, intentional:** the heap size is written **only** into `ProjectZomboid64.json`, and `-Xms`/`-Xmx` are **not** also passed on the command line. Two competing sources for the same value is a documented footgun.

## File Structure

| File | Responsibility |
|---|---|
| `LICENSE` | GPL-3.0 text |
| `.gitignore` | Local data directories, backup artefacts |
| `.pre-commit-config.yaml` | shellcheck, shfmt, hadolint, yamllint hooks |
| `Dockerfile` | Server image |
| `Dockerfile.backup` | Backup sidecar image |
| `docker-compose.yml` | Two services, three volumes, two networks |
| `renovate.json` | Dependency automation |
| `scripts/entrypoint.sh` | Orchestration, signal handling, server supervision |
| `scripts/healthcheck.sh` | Readiness probe |
| `scripts/lib/log.sh` | Uniform logging helpers |
| `scripts/lib/ini.sh` | INI read/patch, mod-list validation |
| `scripts/lib/args.sh` | Server command-line construction |
| `scripts/lib/steam.sh` | SteamCMD install/update, branch selection, retries |
| `scripts/lib/jvm.sh` | Heap configuration in `ProjectZomboid64.json` |
| `scripts/backup/entrypoint.sh` | Backup scheduling loop |
| `scripts/backup/backup-now.sh` | One-shot backup, usable via `compose exec` |
| `scripts/backup/lib/backup.sh` | Archive creation, rotation, duration parsing, notification |
| `tests/unit/*.bats` | Behaviour tests for the bash libraries |
| `tests/helpers/load.bash` | Shared bats helpers |
| `tests/run-unit.sh` | Runs bats in a container |
| `tests/smoke.sh` | End-to-end container test |
| `.github/workflows/{lint,test,release}.yml` | CI |
| `README.md`, `docs/{configuration,backup-restore,runbook}.md` | Documentation |

---

### Task 1: Repository scaffolding and verification guardrails

Set up the linting and test harness first, so every later task has something to run.

**Files:**
- Create: `LICENSE`, `.gitignore`, `.pre-commit-config.yaml`, `.yamllint`, `tests/run-unit.sh`, `tests/helpers/load.bash`, `tests/unit/harness.bats`

**Interfaces:**
- Consumes: nothing
- Produces: `tests/run-unit.sh` — runs every `tests/unit/*.bats` file inside `bats/bats:1.14.0`, mounting the repository at `/code`. Bats files load helpers with `load '../helpers/load'`. `tests/helpers/load.bash` exports `REPO_ROOT` (absolute path to the repository inside the container) and defines `setup_tmpdir`, which creates `$TEST_TMP` and registers cleanup.

- [ ] **Step 1: Create the license and ignore files**

```bash
curl -fsSL -o LICENSE https://www.gnu.org/licenses/gpl-3.0.txt
```

`.gitignore`:

```gitignore
# Local Compose data when bind mounts are used instead of named volumes
/data/
/backups/
.env
*.tar.zst
```

- [ ] **Step 2: Create the bats runner**

`tests/run-unit.sh`:

```bash
#!/usr/bin/env bash
# Runs the unit test suite inside the official bats container, so no local
# installation is required and CI and workstation behave identically.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BATS_IMAGE="${BATS_IMAGE:-bats/bats:1.14.0}"

exec docker run --rm \
  --volume "${REPO_ROOT}:/code" \
  --workdir /code \
  "${BATS_IMAGE}" \
  --print-output-on-failure \
  tests/unit
```

`tests/helpers/load.bash`:

```bash
#!/usr/bin/env bash
# Shared helpers for the bats suite.

REPO_ROOT="${REPO_ROOT:-/code}"
export REPO_ROOT

# Creates a per-test temporary directory in TEST_TMP and removes it afterwards.
setup_tmpdir() {
  TEST_TMP="$(mktemp -d)"
  export TEST_TMP
}

teardown_tmpdir() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "${TEST_TMP}" ]; then
    rm -rf "${TEST_TMP}"
  fi
}
```

- [ ] **Step 3: Write a harness test that proves the runner works**

`tests/unit/harness.bats`:

```bash
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
```

- [ ] **Step 4: Run the harness tests and verify they pass**

Run: `chmod +x tests/run-unit.sh && ./tests/run-unit.sh`
Expected: `2 tests, 0 failures`

- [ ] **Step 5: Create the lint configuration**

`.yamllint`:

```yaml
extends: relaxed
rules:
  line-length:
    max: 120
  truthy:
    allowed-values: ["true", "false", "on"]
```

`.pre-commit-config.yaml`:

```yaml
repos:
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v6.0.0
    hooks:
      - id: end-of-file-fixer
      - id: trailing-whitespace
      - id: check-merge-conflict

  - repo: https://github.com/koalaman/shellcheck-precommit
    rev: v0.11.0
    hooks:
      - id: shellcheck

  - repo: https://github.com/scop/pre-commit-shfmt
    rev: v3.12.0-2
    hooks:
      - id: shfmt
        args: ["-i", "2", "-w"]

  - repo: https://github.com/hadolint/hadolint
    rev: v2.14.0
    hooks:
      - id: hadolint-docker

  - repo: https://github.com/adrienverge/yamllint
    rev: v1.37.1
    hooks:
      - id: yamllint
        args: ["-c", ".yamllint"]
```

- [ ] **Step 6: Install the hooks and verify the whole tree is clean**

Run:
```bash
prek install
prek auto-update --cooldown-days 7
prek run --all-files
```
Expected: every hook passes. If a `rev` above no longer exists, `prek auto-update` corrects it — commit the corrected file.

- [ ] **Step 7: Commit**

```bash
git add LICENSE .gitignore .pre-commit-config.yaml .yamllint tests/
git commit -m "chore: add license, lint hooks and bats test harness"
```

---

### Task 2: INI library

**Files:**
- Create: `scripts/lib/log.sh`, `scripts/lib/ini.sh`
- Test: `tests/unit/ini.bats`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `log_info <msg>`, `log_warn <msg>`, `log_error <msg>` — write `[pz] LEVEL: msg`; `log_warn` and `log_error` go to stderr, `log_info` to stdout.
  - `ini_ensure_file <file>` — creates parent directory and an empty file if absent; returns 0.
  - `ini_get <file> <key>` — prints the value, returns 0; returns 1 when the key is absent.
  - `ini_set <file> <key> <value>` — replaces the first matching `key=` line in place, appends when absent. Preserves comments, ordering, unknown keys and the file's inode.
  - `ini_check_mod_ids <mod_ids> <branch>` — writes one warning per entry lacking a leading backslash when `branch` is `public`; never modifies anything; always returns 0.

- [ ] **Step 1: Write the failing tests**

`tests/unit/ini.bats`:

```bash
#!/usr/bin/env bats

load '../helpers/load'

setup() {
  setup_tmpdir
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/scripts/lib/log.sh"
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/scripts/lib/ini.sh"
  INI="${TEST_TMP}/servertest.ini"
  cat >"${INI}" <<'EOF'
# This is a comment that must survive
Public=false
PublicName=Old Name
Password=
UnknownFutureKey=keepme
EOF
}

teardown() {
  teardown_tmpdir
}

@test "ini_set replaces an existing key" {
  ini_set "${INI}" "Public" "true"
  run grep -c '^Public=true$' "${INI}"
  [ "$output" = "1" ]
}

@test "ini_set does not touch a key that only shares a prefix" {
  ini_set "${INI}" "Public" "true"
  run grep -c '^PublicName=Old Name$' "${INI}"
  [ "$output" = "1" ]
}

@test "ini_set preserves comments and unknown keys" {
  ini_set "${INI}" "Password" "secret"
  grep -q '^# This is a comment that must survive$' "${INI}"
  grep -q '^UnknownFutureKey=keepme$' "${INI}"
}

@test "ini_set appends a key that is missing" {
  ini_set "${INI}" "MaxPlayers" "8"
  run tail -n 1 "${INI}"
  [ "$output" = "MaxPlayers=8" ]
}

@test "ini_set handles values containing sed metacharacters" {
  ini_set "${INI}" "Password" 'a&b|c\d/e'
  run ini_get "${INI}" "Password"
  [ "$output" = 'a&b|c\d/e' ]
}

@test "ini_set ignores a commented-out occurrence of the key" {
  printf '# MaxPlayers=99\n' >>"${INI}"
  ini_set "${INI}" "MaxPlayers" "8"
  grep -q '^# MaxPlayers=99$' "${INI}"
  grep -q '^MaxPlayers=8$' "${INI}"
}

@test "ini_set writes an empty value" {
  ini_set "${INI}" "PublicName" ""
  run ini_get "${INI}" "PublicName"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "ini_get returns 1 for a missing key" {
  run ini_get "${INI}" "NoSuchKey"
  [ "$status" -eq 1 ]
}

@test "ini_ensure_file creates the file and its parent directory" {
  ini_ensure_file "${TEST_TMP}/nested/dir/new.ini"
  [ -f "${TEST_TMP}/nested/dir/new.ini" ]
}

@test "ini_ensure_file leaves an existing file untouched" {
  ini_ensure_file "${INI}"
  grep -q '^UnknownFutureKey=keepme$' "${INI}"
}

@test "ini_check_mod_ids warns for Build 42 ids without a backslash" {
  run ini_check_mod_ids 'FirstMod;\SecondMod' 'public'
  [ "$status" -eq 0 ]
  [[ "$output" == *"FirstMod"* ]]
  [[ "$output" != *"SecondMod has no leading backslash"* ]]
}

@test "ini_check_mod_ids stays silent on the legacy41 branch" {
  run ini_check_mod_ids 'FirstMod;SecondMod' 'legacy41'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "ini_check_mod_ids stays silent for an empty list" {
  run ini_check_mod_ids '' 'public'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./tests/run-unit.sh`
Expected: FAIL — `scripts/lib/log.sh` and `scripts/lib/ini.sh` do not exist yet.

- [ ] **Step 3: Implement the logging helper**

`scripts/lib/log.sh`:

```bash
#!/usr/bin/env bash
# Uniform logging. Warnings and errors go to stderr so they survive log filters.

log_info() {
  printf '[pz] INFO: %s\n' "$*"
}

log_warn() {
  printf '[pz] WARN: %s\n' "$*" >&2
}

log_error() {
  printf '[pz] ERROR: %s\n' "$*" >&2
}
```

- [ ] **Step 4: Implement the INI library**

`scripts/lib/ini.sh`:

```bash
#!/usr/bin/env bash
# Reading and patching of the Project Zomboid server INI file.
#
# The approach of replacing a key in place while leaving everything else alone is
# taken from Danixu/project-zomboid-server-docker (scripts/entry.sh:178-188, GPL-3.0).
# It is reimplemented here in pure bash rather than with sed: the INI holds
# passwords and mod lists, which routinely contain the characters sed treats as
# metacharacters in a replacement.

ini_ensure_file() {
  local file="$1"
  mkdir -p "$(dirname "${file}")"
  if [ ! -f "${file}" ]; then
    : >"${file}"
  fi
}

# Prints the value of a key, or returns 1 when the key is not present.
ini_get() {
  local file="$1" key="$2" line
  [ -f "${file}" ] || return 1
  while IFS= read -r line || [ -n "${line}" ]; do
    if [ "${line%%=*}" = "${key}" ] && [ "${line}" != "${line#*=}" ]; then
      printf '%s\n' "${line#*=}"
      return 0
    fi
  done <"${file}"
  return 1
}

# Replaces the first `key=` line, or appends the pair when the key is absent.
ini_set() {
  local file="$1" key="$2" value="$3"
  local tmp line found=0

  ini_ensure_file "${file}"
  tmp="$(mktemp "${file}.XXXXXX")"

  while IFS= read -r line || [ -n "${line}" ]; do
    if [ "${found}" -eq 0 ] && [ "${line%%=*}" = "${key}" ] &&
      [ "${line}" != "${line#*=}" ]; then
      printf '%s=%s\n' "${key}" "${value}" >>"${tmp}"
      found=1
    else
      printf '%s\n' "${line}" >>"${tmp}"
    fi
  done <"${file}"

  if [ "${found}" -eq 0 ]; then
    printf '%s=%s\n' "${key}" "${value}" >>"${tmp}"
  fi

  # Copy the content instead of renaming, so the original inode, ownership and
  # mode survive. Bind-mounted files must not be replaced by a new file.
  cat "${tmp}" >"${file}"
  rm -f "${tmp}"
}

# Build 42 requires every entry in Mods= to carry a leading backslash; Build 41
# does not. Getting this wrong is the most common cause of "mods do not load".
# This warns and deliberately changes nothing: silently rewriting a user's
# configuration produces behaviour that cannot be reasoned about later.
ini_check_mod_ids() {
  local mod_ids="$1" branch="$2" entry
  if [ "${branch}" != "public" ] || [ -z "${mod_ids}" ]; then
    return 0
  fi
  local IFS=';'
  for entry in ${mod_ids}; do
    if [ -z "${entry}" ]; then
      continue
    fi
    case "${entry}" in
    \\*) ;;
    *)
      log_warn "mod id '${entry}' has no leading backslash. Build 42 expects" \
        "Mods=\\\\${entry}. The value is left unchanged."
      ;;
    esac
  done
  return 0
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./tests/run-unit.sh`
Expected: PASS — all `ini.bats` tests green.

- [ ] **Step 6: Confirm the tests can actually fail**

Temporarily change `[ "${line%%=*}" = "${key}" ]` to `[[ "${line}" == "${key}"* ]]` in `ini_set`, run the suite, and confirm that "does not touch a key that only shares a prefix" fails. Revert the change.

- [ ] **Step 7: Lint and commit**

```bash
shellcheck scripts/lib/log.sh scripts/lib/ini.sh
shfmt -i 2 -d scripts/lib/
git add scripts/lib/log.sh scripts/lib/ini.sh tests/unit/ini.bats
git commit -m "feat: add INI patching library with prefix-safe key matching"
```

---

### Task 3: SteamCMD library

**Files:**
- Create: `scripts/lib/steam.sh`
- Test: `tests/unit/steam.bats`

**Interfaces:**
- Consumes: `log_info`, `log_warn`, `log_error` from `scripts/lib/log.sh`
- Produces:
  - `steam_branch_args <branch>` — populates the global array `STEAM_BRANCH_ARGS`; empty for `public` or an empty branch, otherwise `(-beta <branch>)`.
  - `steam_is_installed <install_dir>` — returns 0 when `<install_dir>/start-server.sh` exists.
  - `steam_install <install_dir> <branch>` — runs `${STEAMCMD_BIN}` (default `/usr/games/steamcmd`) up to `${STEAM_RETRIES}` times (default 3) with `${STEAM_RETRY_DELAY}` seconds between attempts (default 15). Returns 0 on the first success, 1 when every attempt fails.

- [ ] **Step 1: Write the failing tests**

`tests/unit/steam.bats`:

```bash
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

@test "steam_install passes the app id and validate" {
  make_stub 0
  steam_install "${INSTALL_DIR}" "public"
  grep -q '^380870$' "${ARG_LOG}"
  grep -q '^validate$' "${ARG_LOG}"
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

@test "steam_is_installed detects the start script" {
  run steam_is_installed "${INSTALL_DIR}"
  [ "$status" -ne 0 ]
  mkdir -p "${INSTALL_DIR}"
  touch "${INSTALL_DIR}/start-server.sh"
  run steam_is_installed "${INSTALL_DIR}"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./tests/run-unit.sh`
Expected: FAIL — `scripts/lib/steam.sh` does not exist.

- [ ] **Step 3: Implement the library**

`scripts/lib/steam.sh`:

```bash
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./tests/run-unit.sh`
Expected: PASS

- [ ] **Step 5: Lint and commit**

```bash
shellcheck scripts/lib/steam.sh
shfmt -i 2 -d scripts/lib/
git add scripts/lib/steam.sh tests/unit/steam.bats
git commit -m "feat: add SteamCMD install library with branch handling and retries"
```

---

### Task 4: JVM heap library

**Files:**
- Create: `scripts/lib/jvm.sh`
- Test: `tests/unit/jvm.bats`

**Interfaces:**
- Consumes: `log_info`, `log_warn`
- Produces: `jvm_set_heap <json_file> <size>` — rewrites `.vmArgs` in `ProjectZomboid64.json` so it contains exactly one `-Xms<size>` and one `-Xmx<size>`, preserving all other entries and all other JSON keys. Returns 1 with an error when the file does not exist.

- [ ] **Step 1: Write the failing tests**

`tests/unit/jvm.bats`:

```bash
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

@test "jvm_set_heap fails on a missing file" {
  run jvm_set_heap "${TEST_TMP}/absent.json" "4g"
  [ "$status" -eq 1 ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./tests/run-unit.sh`
Expected: FAIL — `scripts/lib/jvm.sh` does not exist.

- [ ] **Step 3: Implement the library**

`scripts/lib/jvm.sh`:

```bash
#!/usr/bin/env bash
# JVM heap configuration for the Project Zomboid server launcher.
#
# The heap size is set here and nowhere else. It could also be passed on the
# command line, but having two sources for the same value is a well known way to
# end up wondering which one the server actually used.

jvm_set_heap() {
  local file="$1" size="$2" tmp

  if [ ! -f "${file}" ]; then
    log_error "JVM configuration ${file} not found. The server installation" \
      "looks incomplete."
    return 1
  fi

  tmp="$(mktemp "${file}.XXXXXX")"
  jq --arg xms "-Xms${size}" --arg xmx "-Xmx${size}" '
    .vmArgs = (
      ((.vmArgs // [])
        | map(select((startswith("-Xms") or startswith("-Xmx")) | not)))
      + [$xms, $xmx]
    )
  ' "${file}" >"${tmp}"

  cat "${tmp}" >"${file}"
  rm -f "${tmp}"
  log_info "JVM heap set to ${size}"
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./tests/run-unit.sh`
Expected: PASS

- [ ] **Step 5: Lint and commit**

```bash
shellcheck scripts/lib/jvm.sh
shfmt -i 2 -d scripts/lib/
git add scripts/lib/jvm.sh tests/unit/jvm.bats
git commit -m "feat: set JVM heap in ProjectZomboid64.json"
```

---

### Task 5: Server argument library

**Files:**
- Create: `scripts/lib/args.sh`
- Test: `tests/unit/args.bats`

**Interfaces:**
- Consumes: `log_info`
- Produces:
  - `args_is_first_boot <data_dir> <server_name>` — returns 0 when `<data_dir>/db/<server_name>.db` does not exist.
  - `args_build <data_dir> <server_name> <first_boot>` — populates the global array `PZ_ARGS`. `first_boot` is the string `true` or `false`. Reads `ADMIN_USERNAME`, `ADMIN_PASSWORD`, `NOSTEAM`, `MODFOLDERS` from the environment. Never emits `-Xms`/`-Xmx` (see Task 4). Emits `-adminusername`/`-adminpassword` only when `first_boot` is `true`, because the server writes its command line to the log in clear text on every start.

- [ ] **Step 1: Write the failing tests**

`tests/unit/args.bats`:

```bash
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

@test "args_build succeeds under set -e with everything unset" {
  set -e
  args_build "${DATA_DIR}" "servertest" "false"
  [ "${#PZ_ARGS[@]}" -gt 0 ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./tests/run-unit.sh`
Expected: FAIL — `scripts/lib/args.sh` does not exist.

- [ ] **Step 3: Implement the library**

`scripts/lib/args.sh`:

```bash
#!/usr/bin/env bash
# Construction of the server command line.
#
# Every value goes into an array element of its own, so names and passwords
# containing spaces reach the server as a single argument.

args_is_first_boot() {
  local data_dir="$1" server_name="$2"
  [ ! -f "${data_dir}/db/${server_name}.db" ]
}

args_build() {
  local data_dir="$1" server_name="$2" first_boot="$3"

  PZ_ARGS=()
  PZ_ARGS+=("-cachedir=${data_dir}")
  PZ_ARGS+=("-servername" "${server_name}")

  # The server writes its full command line into the log on every start, so the
  # admin password is only passed when it is actually needed: on the very first
  # boot, when the account does not exist yet. Afterwards it lives in the world
  # database and re-passing it would leak it into every log file.
  if [ "${first_boot}" = "true" ]; then
    if [ -n "${ADMIN_USERNAME:-}" ]; then
      PZ_ARGS+=("-adminusername" "${ADMIN_USERNAME}")
    fi
    if [ -n "${ADMIN_PASSWORD:-}" ]; then
      PZ_ARGS+=("-adminpassword" "${ADMIN_PASSWORD}")
    fi
  fi

  # Disables Steam integration. Note that this also disables Workshop downloads.
  if [ "${NOSTEAM:-false}" = "true" ]; then
    PZ_ARGS+=("-nosteam")
  fi

  if [ -n "${MODFOLDERS:-}" ]; then
    PZ_ARGS+=("-modfolders" "${MODFOLDERS}")
  fi

  return 0
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./tests/run-unit.sh`
Expected: PASS

- [ ] **Step 5: Lint and commit**

```bash
shellcheck scripts/lib/args.sh
shfmt -i 2 -d scripts/lib/
git add scripts/lib/args.sh tests/unit/args.bats
git commit -m "feat: build server arguments, passing admin password only on first boot"
```

---

### Task 6: Entrypoint with graceful shutdown

**Files:**
- Create: `scripts/entrypoint.sh`
- Test: `tests/unit/entrypoint.bats`

**Interfaces:**
- Consumes: everything from `scripts/lib/`
- Produces: the container entrypoint. Honours `PZ_SKIP_INSTALL=true` to bypass the SteamCMD and INI phases, which is what makes it testable without downloading 3 GB. Reads `PZ_SERVER_DIR` (default `/data/server`), `PZ_DATA_DIR` (default `/data/zomboid`), `PZ_BRANCH`, `PZ_MAX_RAM`, `UPDATE_ON_START`, `SERVER_NAME`, and the INI variables mapped in `configure_phase` below
(`SERVER_PASSWORD`, `RCON_PASSWORD`, `RCON_PORT`, `PUBLIC`, `PUBLIC_NAME`, `MAX_PLAYERS`,
`GAME_PORT`, `UDP_PORT`, `MOD_IDS`, `WORKSHOP_IDS`, `SELF_MANAGED_MODS`).

- [ ] **Step 1: Write the failing tests**

`tests/unit/entrypoint.bats`:

```bash
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
}

teardown() {
  teardown_tmpdir
}

@test "entrypoint sends quit on SIGTERM and waits for the save" {
  "${REPO_ROOT}/scripts/entrypoint.sh" >"${TEST_TMP}/out.log" 2>&1 &
  local pid=$!

  # Wait for the stand-in server to announce readiness.
  local waited=0
  while ! grep -q "SERVER STARTED" "${TEST_TMP}/out.log" 2>/dev/null; do
    sleep 0.1
    waited=$((waited + 1))
    [ "$waited" -lt 100 ] || break
  done

  kill -TERM "$pid"
  wait "$pid"
  local status=$?

  [ -f "${TEST_TMP}/saved.marker" ]
  [ "$status" -eq 0 ]
  grep -q "console: quit" "${TEST_TMP}/out.log"
}

@test "entrypoint fails fast when the data directory is not writable" {
  chmod 500 "${DATA_DIR}"
  run "${REPO_ROOT}/scripts/entrypoint.sh"
  chmod 700 "${DATA_DIR}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not writable"* ]]
}

@test "entrypoint fails when the server is not installed and install is skipped" {
  rm -f "${SERVER_DIR}/start-server.sh"
  run "${REPO_ROOT}/scripts/entrypoint.sh"
  [ "$status" -ne 0 ]
}
```

Note for the implementer: the second test must run as a non-root user for the
permission check to take effect. The bats container runs as root by default, in
which case the mode bits are ignored. Guard it with
`if [ "$(id -u)" -eq 0 ]; then skip "permission checks are meaningless as root"; fi`
as the first line of that test.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./tests/run-unit.sh`
Expected: FAIL — `scripts/entrypoint.sh` does not exist.

- [ ] **Step 3: Implement the entrypoint**

`scripts/entrypoint.sh`:

```bash
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

# Sets an INI key from an environment variable, skipping it when unset. An empty
# but defined variable is written, so a value can be cleared deliberately.
ini_set_from_env() {
  local ini="$1" key="$2" var="$3"
  if [ -z "${!var+defined}" ]; then
    return 0
  fi
  ini_set "${ini}" "${key}" "${!var}"
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
    wait "${SERVER_PID}"
    SHUTDOWN_EXIT=$?
    if [ "${SHUTDOWN_EXIT}" -le 128 ] || ! kill -0 "${SERVER_PID}" 2>/dev/null; then
      break
    fi
    log_info "Still saving, waiting for the server to finish"
  done
  log_info "Server stopped cleanly with exit code ${SHUTDOWN_EXIT}"
}

start_server() {
  if ! steam_is_installed "${PZ_SERVER_DIR}"; then
    log_error "No start-server.sh in ${PZ_SERVER_DIR}; installation incomplete."
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./tests/run-unit.sh`
Expected: PASS — in particular `saved.marker` exists, proving the shutdown path completed rather than being killed.

- [ ] **Step 5: Confirm the shutdown test can fail**

Temporarily replace `printf 'quit\n' >&"${CONSOLE_FD}"` with `true`, run the suite, and confirm the SIGTERM test fails because `saved.marker` is absent. Revert.

- [ ] **Step 6: Lint and commit**

```bash
shellcheck scripts/entrypoint.sh
shfmt -i 2 -d scripts/
git add scripts/entrypoint.sh tests/unit/entrypoint.bats
git commit -m "feat: add entrypoint with FIFO-based graceful shutdown"
```

---

### Task 7: Healthcheck

**Files:**
- Create: `scripts/healthcheck.sh`
- Test: `tests/unit/healthcheck.bats`

**Interfaces:**
- Consumes: nothing from the libraries; it must stay dependency-light because Docker runs it every few seconds.
- Produces: exit 0 when the server accepts players. With `RCON_PASSWORD` set it runs `${RCON_BIN:-rcon} -a 127.0.0.1:${RCON_PORT} -p <password> players`. Without it, it falls back to checking that a `ProjectZomboid` process exists and that `${GAME_PORT}` is bound for UDP.

- [ ] **Step 1: Write the failing tests**

`tests/unit/healthcheck.bats`:

```bash
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
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./tests/run-unit.sh`
Expected: FAIL — `scripts/healthcheck.sh` does not exist.

- [ ] **Step 3: Implement the healthcheck**

`scripts/healthcheck.sh`:

```bash
#!/usr/bin/env bash
# Reports whether the server actually accepts players, not merely whether the
# JVM process is alive.
set -uo pipefail

RCON_BIN="${RCON_BIN:-rcon}"
RCON_PORT="${RCON_PORT:-27015}"
GAME_PORT="${GAME_PORT:-16261}"

if [ -n "${RCON_PASSWORD:-}" ]; then
  # Output is discarded: it would otherwise end up in `docker inspect` health
  # logs, and the command line already carries the password.
  if "${RCON_BIN}" -a "127.0.0.1:${RCON_PORT}" -p "${RCON_PASSWORD}" \
    players >/dev/null 2>&1; then
    exit 0
  fi
  echo "RCON did not answer on port ${RCON_PORT}"
  exit 1
fi

# Fallback for servers without RCON. Weaker, because a JVM that is still
# generating the world also passes it once the socket is bound.
if ! pgrep -f "ProjectZomboid" >/dev/null 2>&1; then
  echo "No ProjectZomboid process found"
  exit 1
fi

if ! ss -lun 2>/dev/null | grep -q ":${GAME_PORT}"; then
  echo "UDP port ${GAME_PORT} is not bound"
  exit 1
fi

exit 0
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./tests/run-unit.sh`
Expected: PASS

- [ ] **Step 5: Lint and commit**

```bash
shellcheck scripts/healthcheck.sh
shfmt -i 2 -d scripts/
git add scripts/healthcheck.sh tests/unit/healthcheck.bats
git commit -m "feat: add RCON-based healthcheck with process fallback"
```

---

### Task 8: Server image

**Files:**
- Create: `Dockerfile`, `.dockerignore`

**Interfaces:**
- Consumes: everything under `scripts/`
- Produces: image with entrypoint `/opt/pz/scripts/entrypoint.sh`, healthcheck `/opt/pz/scripts/healthcheck.sh`, running as uid/gid 1000 (`pz`), with `/data/server` and `/data/zomboid` pre-created and owned by `pz`.

- [ ] **Step 1: Create `.dockerignore`**

```gitignore
.git
.github
docs
tests
data
backups
*.md
```

- [ ] **Step 2: Write the Dockerfile**

`Dockerfile`:

```dockerfile
# syntax=docker/dockerfile:1

# ---- rcon-cli ----------------------------------------------------------------
FROM steamcmd/steamcmd:ubuntu-24@sha256:2fbec2969d6caf1d203b62a365c0198c17c7eb9859b39f715c8acabfe917c182 AS rcon

ARG RCON_VERSION=0.10.3
ARG RCON_SHA256=6962a641ebf9a5957bd0cda1b8acf3e34a23686ae709f6c6a14ac3898521a5cc

# hadolint ignore=DL3008
# Version pinning is handled by the digest-pinned base image; pinning apt
# versions on top of it would break the image on every Ubuntu point release.
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl \
  && rm -rf /var/lib/apt/lists/* \
  && curl -fsSL -o /tmp/rcon.tar.gz \
  "https://github.com/gorcon/rcon-cli/releases/download/v${RCON_VERSION}/rcon-${RCON_VERSION}-amd64_linux.tar.gz" \
  && echo "${RCON_SHA256}  /tmp/rcon.tar.gz" | sha256sum -c - \
  && tar -xzf /tmp/rcon.tar.gz -C /tmp \
  && install -m 0755 "/tmp/rcon-${RCON_VERSION}-amd64_linux/rcon" /usr/local/bin/rcon

# ---- runtime -----------------------------------------------------------------
FROM steamcmd/steamcmd:ubuntu-24@sha256:2fbec2969d6caf1d203b62a365c0198c17c7eb9859b39f715c8acabfe917c182

LABEL org.opencontainers.image.title="Project Zomboid Dedicated Server" \
  org.opencontainers.image.description="Project Zomboid dedicated server, installed from Steam into a volume at runtime" \
  org.opencontainers.image.licenses="GPL-3.0-or-later" \
  org.opencontainers.image.source="https://github.com/SWATPeaceKeeper/zomboid-server-docker"

# hadolint ignore=DL3008
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
  ca-certificates \
  iproute2 \
  jq \
  procps \
  tzdata \
  && rm -rf /var/lib/apt/lists/*

# Ubuntu 24.04 ships an `ubuntu` account that already occupies uid/gid 1000, so
# it has to go before the service account can claim that id. 1000 is used
# because it matches the default uid on the typical Docker host, which keeps
# bind-mount ownership straightforward.
RUN userdel -r ubuntu \
  && groupadd -g 1000 pz \
  && useradd -u 1000 -g 1000 -m -d /home/pz -s /bin/bash pz \
  && mkdir -p /data/server /data/zomboid /opt/pz \
  && chown -R pz:pz /data /opt/pz

COPY --from=rcon --chown=root:root /usr/local/bin/rcon /usr/local/bin/rcon
COPY --chown=pz:pz scripts/ /opt/pz/scripts/

RUN chmod 0755 /opt/pz/scripts/entrypoint.sh /opt/pz/scripts/healthcheck.sh

ENV PZ_SERVER_DIR=/data/server \
  PZ_DATA_DIR=/data/zomboid \
  PZ_BRANCH=public \
  PZ_MAX_RAM=4g \
  UPDATE_ON_START=true \
  SERVER_NAME=servertest \
  HOME=/home/pz

USER pz
WORKDIR /data/server

EXPOSE 16261/udp 16262/udp

# start_period is generous because a first boot downloads the server and
# generates a world before it can answer anything.
HEALTHCHECK --interval=30s --timeout=10s --start-period=900s --retries=3 \
  CMD /opt/pz/scripts/healthcheck.sh

ENTRYPOINT ["/opt/pz/scripts/entrypoint.sh"]
```

- [ ] **Step 3: Lint the Dockerfile**

Run: `hadolint Dockerfile`
Expected: no output. If a rule fires that is not already suppressed, either fix it or add a `# hadolint ignore=<rule>` line with a justification comment — never leave a warning unaddressed.

- [ ] **Step 4: Build the image and verify the user and tooling**

```bash
docker build -t pz-server:dev .
docker run --rm --entrypoint /bin/bash pz-server:dev -c 'id; command -v rcon jq ss'
```
Expected: `uid=1000(pz) gid=1000(pz)` and all three binaries resolve.

- [ ] **Step 5: Verify the image does not contain server files**

```bash
docker run --rm --entrypoint /bin/bash pz-server:dev -c 'ls -A /data/server | wc -l'
```
Expected: `0` — the image must ship no Project Zomboid content.

- [ ] **Step 6: Commit**

```bash
git add Dockerfile .dockerignore
git commit -m "feat: add server image running as uid 1000 without baked game files"
```

---

### Task 9: Compose stack and end-to-end smoke test

**Files:**
- Create: `docker-compose.yml`, `tests/smoke.sh`

**Interfaces:**
- Consumes: the `pz-server` image from Task 8
- Produces: a Compose stack with the `pz-server` service, the `pz-server`/`pz-zomboid`/`pz-backups` volumes and the `pz-internal` network. The `pz-backup` service is added in Task 10. `tests/smoke.sh` builds the image, starts a container, waits for `healthy`, saves over RCON, stops it and asserts a clean exit with a populated `Saves/` directory.

- [ ] **Step 1: Write the Compose file**

`docker-compose.yml`:

```yaml
---
services:
  pz-server:
    build:
      context: .
    image: ghcr.io/swatpeacekeeper/zomboid-server-docker:latest
    container_name: pz-server
    restart: unless-stopped
    # The entrypoint answers SIGTERM by sending `quit` and waiting for the world
    # to be written. Docker's 10s default would SIGKILL a large world mid-save.
    stop_grace_period: 180s
    environment:
      PZ_BRANCH: "${PZ_BRANCH:-public}"
      PZ_MAX_RAM: "${PZ_MAX_RAM:-4g}"
      UPDATE_ON_START: "${UPDATE_ON_START:-true}"
      SERVER_NAME: "${SERVER_NAME:-servertest}"
      PUBLIC_NAME: "${PUBLIC_NAME:-Project Zomboid Server}"
      PUBLIC: "${PUBLIC:-false}"
      MAX_PLAYERS: "${MAX_PLAYERS:-16}"
      GAME_PORT: "${GAME_PORT:-16261}"
      UDP_PORT: "${UDP_PORT:-16262}"
      RCON_PORT: "${RCON_PORT:-27015}"
      ADMIN_USERNAME: "${ADMIN_USERNAME:-admin}"
      ADMIN_PASSWORD: "${PZ_ADMIN_PASSWORD:?set PZ_ADMIN_PASSWORD in your .env}"
      RCON_PASSWORD: "${PZ_RCON_PASSWORD:?set PZ_RCON_PASSWORD in your .env}"
      SERVER_PASSWORD: "${PZ_SERVER_PASSWORD:-}"
      MOD_IDS: "${MOD_IDS:-}"
      WORKSHOP_IDS: "${WORKSHOP_IDS:-}"
      TZ: "${TZ:-Europe/Berlin}"
    ports:
      # Only the game ports are published. RCON stays on the internal network:
      # publishing it would hand out remote server administration.
      - "${GAME_PORT:-16261}:${GAME_PORT:-16261}/udp"
      - "${UDP_PORT:-16262}:${UDP_PORT:-16262}/udp"
    volumes:
      - pz-server:/data/server
      - pz-zomboid:/data/zomboid
    networks:
      - pz-internal
    security_opt:
      - no-new-privileges:true

volumes:
  pz-server:
  pz-zomboid:
  pz-backups:

networks:
  pz-internal:
    internal: true
```

- [ ] **Step 2: Validate the Compose file**

```bash
PZ_ADMIN_PASSWORD=x PZ_RCON_PASSWORD=y docker compose config >/dev/null
yamllint -c .yamllint docker-compose.yml
```
Expected: both silent.

- [ ] **Step 3: Verify the required-variable guard actually fires**

```bash
docker compose config 2>&1 | grep -q "set PZ_ADMIN_PASSWORD" && echo GUARD-OK
```
Expected: `GUARD-OK` — starting without a password must fail loudly rather than boot an open server.

- [ ] **Step 4: Write the smoke test**

`tests/smoke.sh`:

```bash
#!/usr/bin/env bash
# End-to-end test: the server installs, becomes healthy, saves and shuts down
# cleanly. This is the check that a published image is actually usable.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${SMOKE_IMAGE:-pz-server:smoke}"
CONTAINER="pz-smoke-$$"
RCON_PASSWORD="smoke-rcon-password"
READY_TIMEOUT="${SMOKE_TIMEOUT:-1200}"

cleanup() {
  docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
  docker volume rm -f "${CONTAINER}-server" "${CONTAINER}-data" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> Building ${IMAGE}"
docker build -t "${IMAGE}" "${REPO_ROOT}"

echo "==> Starting ${CONTAINER}"
docker volume create "${CONTAINER}-server" >/dev/null
docker volume create "${CONTAINER}-data" >/dev/null
docker run --detach \
  --name "${CONTAINER}" \
  --volume "${CONTAINER}-server:/data/server" \
  --volume "${CONTAINER}-data:/data/zomboid" \
  --env "ADMIN_PASSWORD=smoke-admin-password" \
  --env "RCON_PASSWORD=${RCON_PASSWORD}" \
  --env "SERVER_NAME=smoketest" \
  --env "PZ_MAX_RAM=2g" \
  "${IMAGE}" >/dev/null

echo "==> Waiting up to ${READY_TIMEOUT}s for the container to become healthy"
deadline=$(($(date +%s) + READY_TIMEOUT))
while true; do
  state="$(docker inspect -f '{{.State.Health.Status}}' "${CONTAINER}" 2>/dev/null || echo missing)"
  running="$(docker inspect -f '{{.State.Running}}' "${CONTAINER}" 2>/dev/null || echo false)"
  if [ "${state}" = "healthy" ]; then
    break
  fi
  if [ "${running}" != "true" ]; then
    echo "!! Container exited before becoming healthy" >&2
    docker logs "${CONTAINER}" >&2
    exit 1
  fi
  if [ "$(date +%s)" -ge "${deadline}" ]; then
    echo "!! Timed out waiting for health (last state: ${state})" >&2
    docker logs --tail 100 "${CONTAINER}" >&2
    exit 1
  fi
  sleep 10
done
echo "==> Healthy"

echo "==> Saving the world over RCON"
docker exec "${CONTAINER}" rcon -a "127.0.0.1:27015" -p "${RCON_PASSWORD}" save

echo "==> Stopping the container and checking the shutdown is clean"
docker stop --timeout 180 "${CONTAINER}" >/dev/null
exit_code="$(docker inspect -f '{{.State.ExitCode}}' "${CONTAINER}")"
if [ "${exit_code}" != "0" ]; then
  echo "!! Container exited with ${exit_code}, expected 0" >&2
  docker logs --tail 100 "${CONTAINER}" >&2
  exit 1
fi

if ! docker logs "${CONTAINER}" 2>&1 | grep -q "Server stopped cleanly"; then
  echo "!! Shutdown handler did not report a clean stop" >&2
  exit 1
fi

echo "==> Checking the world was written"
save_count="$(docker run --rm \
  --volume "${CONTAINER}-data:/data/zomboid" \
  --entrypoint /bin/bash "${IMAGE}" \
  -c 'find /data/zomboid/Saves -type f 2>/dev/null | wc -l')"
if [ "${save_count}" -lt 1 ]; then
  echo "!! Saves directory is empty after a clean shutdown" >&2
  exit 1
fi

echo "==> Smoke test passed (${save_count} files under Saves/)"
```

- [ ] **Step 5: Run the smoke test**

Run: `chmod +x tests/smoke.sh && ./tests/smoke.sh`
Expected: `==> Smoke test passed` after roughly 10–20 minutes on the first run. If it times out during world generation, raise `SMOKE_TIMEOUT` rather than weakening the assertions.

- [ ] **Step 6: Commit**

```bash
git add docker-compose.yml tests/smoke.sh
git commit -m "feat: add compose stack and end-to-end smoke test"
```

---

### Task 10: Backup sidecar

**Files:**
- Create: `Dockerfile.backup`, `scripts/backup/lib/backup.sh`, `scripts/backup/entrypoint.sh`, `scripts/backup/backup-now.sh`
- Modify: `docker-compose.yml` (add the `pz-backup` service)
- Test: `tests/unit/backup.bats`

**Interfaces:**
- Consumes: `log_info`, `log_warn`, `log_error`
- Produces:
  - `backup_duration_to_seconds <duration>` — accepts `90`, `30s`, `15m`, `6h`, `1d`; prints seconds; returns 1 on anything else.
  - `backup_create <data_dir> <backup_dir> <mode>` — creates `pz-<UTC timestamp>.tar.zst` for mode `tar`, or the directory `pz-<UTC timestamp>/` for mode `dir`; prints the resulting path.
  - `backup_rotate <backup_dir> <keep>` — deletes the oldest entries matching `pz-*` until at most `keep` remain.
  - `backup_notify <status> <message>` — POSTs to `${NTFY_URL}` when set, otherwise does nothing; always returns 0.

- [ ] **Step 1: Write the failing tests**

`tests/unit/backup.bats`:

```bash
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
  mkdir -p "${DATA_DIR}/Saves/Multiplayer/servertest" "${BACKUP_DIR}"
  echo "world data" >"${DATA_DIR}/Saves/Multiplayer/servertest/map.bin"
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
}

@test "backup_create writes a tar archive in tar mode" {
  run backup_create "${DATA_DIR}" "${BACKUP_DIR}" "tar"
  [ "$status" -eq 0 ]
  [ -f "$output" ]
  [[ "$output" == *.tar.zst ]]
}

@test "backup_create writes a directory copy in dir mode" {
  run backup_create "${DATA_DIR}" "${BACKUP_DIR}" "dir"
  [ "$status" -eq 0 ]
  [ -d "$output" ]
  [ -f "${output}/Saves/Multiplayer/servertest/map.bin" ]
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

@test "backup_rotate leaves unrelated files alone" {
  touch "${BACKUP_DIR}/pz-20260101-000000.tar.zst"
  touch "${BACKUP_DIR}/README.txt"
  backup_rotate "${BACKUP_DIR}" 0
  [ -f "${BACKUP_DIR}/README.txt" ]
}

@test "backup_notify is a no-op without NTFY_URL" {
  run backup_notify "failure" "something broke"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./tests/run-unit.sh`
Expected: FAIL — `scripts/backup/lib/backup.sh` does not exist.

- [ ] **Step 3: Implement the backup library**

`scripts/backup/lib/backup.sh`:

```bash
#!/usr/bin/env bash
# World backup: archive creation, rotation and optional notification.

# Converts 90 / 30s / 15m / 6h / 1d into seconds.
backup_duration_to_seconds() {
  local value="$1" number unit
  if [[ "${value}" =~ ^([0-9]+)([smhd]?)$ ]]; then
    number="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
  else
    log_error "Cannot parse duration '${value}'. Use 90, 30s, 15m, 6h or 1d."
    return 1
  fi

  case "${unit}" in
  "" | s) printf '%s\n' "${number}" ;;
  m) printf '%s\n' "$((number * 60))" ;;
  h) printf '%s\n' "$((number * 3600))" ;;
  d) printf '%s\n' "$((number * 86400))" ;;
  esac
}

# Creates a backup and prints its path. `dir` mode exists because deduplicating
# backup tools such as Borg handle a plain directory far better than a fresh
# compressed archive on every run.
backup_create() {
  local data_dir="$1" backup_dir="$2" mode="$3"
  local stamp target

  if [ ! -d "${data_dir}/Saves" ]; then
    log_error "No Saves directory in ${data_dir}; refusing to write an empty backup."
    return 1
  fi

  stamp="$(date -u +%Y%m%d-%H%M%S)"
  mkdir -p "${backup_dir}"

  case "${mode}" in
  tar)
    target="${backup_dir}/pz-${stamp}.tar.zst"
    tar --use-compress-program=zstd \
      -cf "${target}" -C "${data_dir}" Saves Server
    ;;
  dir)
    target="${backup_dir}/pz-${stamp}"
    mkdir -p "${target}"
    cp -a "${data_dir}/Saves" "${target}/Saves"
    if [ -d "${data_dir}/Server" ]; then
      cp -a "${data_dir}/Server" "${target}/Server"
    fi
    ;;
  *)
    log_error "Unknown BACKUP_MODE '${mode}'. Use 'tar' or 'dir'."
    return 1
    ;;
  esac

  printf '%s\n' "${target}"
}

# Removes the oldest pz-* entries until at most `keep` remain. Anything that is
# not one of our own backups is left alone.
backup_rotate() {
  local backup_dir="$1" keep="$2"
  local entries=() count remove i line

  while IFS= read -r line; do
    entries+=("${line}")
  done < <(find "${backup_dir}" -maxdepth 1 -name 'pz-*' -printf '%f\n' 2>/dev/null | sort)

  count="${#entries[@]}"
  if [ "${count}" -le "${keep}" ]; then
    return 0
  fi

  remove=$((count - keep))
  for ((i = 0; i < remove; i++)); do
    rm -rf "${backup_dir:?}/${entries[$i]}"
    log_info "Removed old backup ${entries[$i]}"
  done
}

# Sends a notification when NTFY_URL is configured. Never fails the caller: a
# backup that succeeded must not be reported as broken because a notification
# could not be delivered.
backup_notify() {
  local status="$1" message="$2"
  if [ -z "${NTFY_URL:-}" ]; then
    return 0
  fi
  local priority="default"
  if [ "${status}" = "failure" ]; then
    priority="high"
  fi
  curl -fsS --max-time 10 \
    -H "Title: Project Zomboid backup ${status}" \
    -H "Priority: ${priority}" \
    ${NTFY_TOKEN:+-H "Authorization: Bearer ${NTFY_TOKEN}"} \
    -d "${message}" \
    "${NTFY_URL}" >/dev/null 2>&1 ||
    log_warn "Could not send the ntfy notification"
  return 0
}
```

Note for the implementer: the `${NTFY_TOKEN:+-H "..."}` expansion is deliberately
unquoted so it disappears entirely when the token is unset. Shellcheck flags this
as SC2086; add `# shellcheck disable=SC2086` directly above the `curl` call with a
comment saying why, per the zero-warnings policy.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./tests/run-unit.sh`
Expected: PASS

- [ ] **Step 5: Implement the backup entrypoint and the one-shot script**

`scripts/backup/backup-now.sh`:

```bash
#!/usr/bin/env bash
# Takes a single backup: save over RCON, archive, rotate. Usable directly via
# `docker compose exec pz-backup backup-now`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/log.sh
source "${SCRIPT_DIR}/../lib/log.sh"
# shellcheck source=lib/backup.sh
source "${SCRIPT_DIR}/lib/backup.sh"

PZ_DATA_DIR="${PZ_DATA_DIR:-/data/zomboid}"
BACKUP_DIR="${BACKUP_DIR:-/data/backups}"
BACKUP_MODE="${BACKUP_MODE:-tar}"
BACKUP_KEEP="${BACKUP_KEEP:-14}"
RCON_HOST="${RCON_HOST:-pz-server}"
RCON_PORT="${RCON_PORT:-27015}"

save_world() {
  if [ -z "${RCON_PASSWORD:-}" ]; then
    log_warn "RCON_PASSWORD is not set; backing up without asking the server" \
      "to save first. The archive may be missing the most recent changes."
    return 0
  fi
  if rcon -a "${RCON_HOST}:${RCON_PORT}" -p "${RCON_PASSWORD}" save >/dev/null 2>&1; then
    log_info "Server acknowledged the save command"
    # The save is asynchronous; give it a moment to reach disk before archiving.
    sleep "${BACKUP_SAVE_WAIT:-20}"
    return 0
  fi
  log_warn "Could not reach RCON at ${RCON_HOST}:${RCON_PORT}; backing up anyway"
}

main() {
  local archive
  save_world
  if ! archive="$(backup_create "${PZ_DATA_DIR}" "${BACKUP_DIR}" "${BACKUP_MODE}")"; then
    backup_notify "failure" "Backup failed; see the container log."
    return 1
  fi
  log_info "Created ${archive}"
  backup_rotate "${BACKUP_DIR}" "${BACKUP_KEEP}"
}

main "$@"
```

`scripts/backup/entrypoint.sh`:

```bash
#!/usr/bin/env bash
# Scheduling loop for world backups.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/log.sh
source "${SCRIPT_DIR}/../lib/log.sh"
# shellcheck source=lib/backup.sh
source "${SCRIPT_DIR}/lib/backup.sh"

BACKUP_INTERVAL="${BACKUP_INTERVAL:-6h}"
BACKUP_ON_START="${BACKUP_ON_START:-true}"

TERMINATE=""
handle_term() {
  TERMINATE=1
  log_info "Shutdown requested, finishing the current cycle"
}
trap handle_term TERM INT

main() {
  local interval_seconds
  interval_seconds="$(backup_duration_to_seconds "${BACKUP_INTERVAL}")"
  log_info "Backup loop started, interval ${BACKUP_INTERVAL} (${interval_seconds}s)"

  # A backup taken at start captures the state before the freshly started server
  # writes to it, which is in practice the state of the last clean shutdown.
  if [ "${BACKUP_ON_START}" = "true" ]; then
    "${SCRIPT_DIR}/backup-now.sh" || log_error "Startup backup failed"
  fi

  while [ -z "${TERMINATE}" ]; do
    # Sleeping in the background and waiting on it lets a signal interrupt the
    # wait immediately instead of after a full interval.
    sleep "${interval_seconds}" &
    wait $! || true
    if [ -n "${TERMINATE}" ]; then
      break
    fi
    "${SCRIPT_DIR}/backup-now.sh" || log_error "Scheduled backup failed"
  done

  log_info "Backup loop stopped"
}

main "$@"
```

- [ ] **Step 6: Write the sidecar Dockerfile**

`Dockerfile.backup`:

```dockerfile
# syntax=docker/dockerfile:1
FROM steamcmd/steamcmd:ubuntu-24@sha256:2fbec2969d6caf1d203b62a365c0198c17c7eb9859b39f715c8acabfe917c182 AS rcon

ARG RCON_VERSION=0.10.3
ARG RCON_SHA256=6962a641ebf9a5957bd0cda1b8acf3e34a23686ae709f6c6a14ac3898521a5cc

# hadolint ignore=DL3008
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl \
  && rm -rf /var/lib/apt/lists/* \
  && curl -fsSL -o /tmp/rcon.tar.gz \
  "https://github.com/gorcon/rcon-cli/releases/download/v${RCON_VERSION}/rcon-${RCON_VERSION}-amd64_linux.tar.gz" \
  && echo "${RCON_SHA256}  /tmp/rcon.tar.gz" | sha256sum -c - \
  && tar -xzf /tmp/rcon.tar.gz -C /tmp \
  && install -m 0755 "/tmp/rcon-${RCON_VERSION}-amd64_linux/rcon" /usr/local/bin/rcon

FROM debian:13-slim

LABEL org.opencontainers.image.title="Project Zomboid backup sidecar" \
  org.opencontainers.image.licenses="GPL-3.0-or-later" \
  org.opencontainers.image.source="https://github.com/SWATPeaceKeeper/zomboid-server-docker"

# hadolint ignore=DL3008
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
  ca-certificates curl tzdata zstd \
  && rm -rf /var/lib/apt/lists/* \
  && groupadd -g 1000 pz \
  && useradd -u 1000 -g 1000 -m -d /home/pz -s /bin/bash pz \
  && mkdir -p /data/backups /opt/pz \
  && chown -R pz:pz /data /opt/pz

COPY --from=rcon /usr/local/bin/rcon /usr/local/bin/rcon
COPY --chown=pz:pz scripts/lib/log.sh /opt/pz/scripts/lib/log.sh
COPY --chown=pz:pz scripts/backup/ /opt/pz/scripts/backup/

RUN chmod 0755 /opt/pz/scripts/backup/entrypoint.sh \
  /opt/pz/scripts/backup/backup-now.sh \
  && ln -s /opt/pz/scripts/backup/backup-now.sh /usr/local/bin/backup-now

USER pz
WORKDIR /data

ENTRYPOINT ["/opt/pz/scripts/backup/entrypoint.sh"]
```

Note: `debian:13-slim` should be pinned by digest. Resolve the current digest
with the command below and paste it into the `FROM` line before committing:

```bash
docker buildx imagetools inspect debian:13-slim --format '{{.Manifest.Digest}}'
```

- [ ] **Step 7: Add the sidecar to Compose**

Insert into `docker-compose.yml` under `services:`, after `pz-server`:

```yaml
  pz-backup:
    build:
      context: .
      dockerfile: Dockerfile.backup
    image: ghcr.io/swatpeacekeeper/zomboid-server-docker-backup:latest
    container_name: pz-backup
    restart: unless-stopped
    stop_grace_period: 60s
    depends_on:
      - pz-server
    environment:
      BACKUP_INTERVAL: "${BACKUP_INTERVAL:-6h}"
      BACKUP_KEEP: "${BACKUP_KEEP:-14}"
      BACKUP_MODE: "${BACKUP_MODE:-tar}"
      BACKUP_ON_START: "${BACKUP_ON_START:-true}"
      RCON_HOST: "pz-server"
      RCON_PORT: "${RCON_PORT:-27015}"
      RCON_PASSWORD: "${PZ_RCON_PASSWORD:?set PZ_RCON_PASSWORD in your .env}"
      NTFY_URL: "${NTFY_URL:-}"
      NTFY_TOKEN: "${NTFY_TOKEN:-}"
      TZ: "${TZ:-Europe/Berlin}"
    volumes:
      - pz-zomboid:/data/zomboid:ro
      - pz-backups:/data/backups
    networks:
      - pz-internal
    security_opt:
      - no-new-privileges:true
```

- [ ] **Step 8: Verify the sidecar end to end**

```bash
docker build -f Dockerfile.backup -t pz-backup:dev .
docker volume create pz-backup-test-data
docker run --rm -v pz-backup-test-data:/data/zomboid --entrypoint /bin/bash pz-backup:dev \
  -c 'mkdir -p /data/zomboid/Saves/x && echo world > /data/zomboid/Saves/x/map.bin'
docker run --rm \
  -v pz-backup-test-data:/data/zomboid:ro \
  -v pz-backup-test-out:/data/backups \
  -e BACKUP_ON_START=true -e BACKUP_INTERVAL=1d \
  --entrypoint /usr/local/bin/backup-now \
  pz-backup:dev
docker run --rm -v pz-backup-test-out:/data/backups --entrypoint /bin/bash pz-backup:dev \
  -c 'ls -l /data/backups'
```
Expected: exactly one `pz-<timestamp>.tar.zst`, and the log warns that RCON is
unreachable rather than failing the backup.

Clean up: `docker volume rm pz-backup-test-data pz-backup-test-out`

- [ ] **Step 9: Lint and commit**

```bash
shellcheck scripts/backup/entrypoint.sh scripts/backup/backup-now.sh scripts/backup/lib/backup.sh
shfmt -i 2 -d scripts/
hadolint Dockerfile.backup
yamllint -c .yamllint docker-compose.yml
git add Dockerfile.backup scripts/backup/ tests/unit/backup.bats docker-compose.yml
git commit -m "feat: add backup sidecar with tar and borg-friendly directory modes"
```

---

### Task 11: Continuous integration

**Files:**
- Create: `.github/workflows/lint.yml`, `.github/workflows/test.yml`, `.github/workflows/release.yml`, `renovate.json`

**Interfaces:**
- Consumes: `tests/run-unit.sh`, `tests/smoke.sh`, both Dockerfiles
- Produces: three workflows and a Renovate configuration.

- [ ] **Step 1: Write the lint workflow**

`.github/workflows/lint.yml`:

```yaml
---
name: Lint

"on":
  push:
    branches: [main]
  pull_request:

permissions:
  contents: read

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1  # v7.0.1
        with:
          persist-credentials: false

      - name: Run shellcheck
        run: |
          sudo apt-get update
          sudo apt-get install -y shellcheck
          find scripts tests -name '*.sh' -print0 | xargs -0 shellcheck

      - name: Check shell formatting
        run: |
          curl -fsSL -o /tmp/shfmt \
            https://github.com/mvdan/sh/releases/download/v3.12.0/shfmt_v3.12.0_linux_amd64
          chmod +x /tmp/shfmt
          find scripts tests -name '*.sh' -print0 | xargs -0 /tmp/shfmt -i 2 -d

      - name: Lint the server Dockerfile
        uses: hadolint/hadolint-action@06be81baf89a55ffd0e24b8f04a4185738dd3387  # v3.5.0
        with:
          dockerfile: Dockerfile

      - name: Lint the backup Dockerfile
        uses: hadolint/hadolint-action@06be81baf89a55ffd0e24b8f04a4185738dd3387  # v3.5.0
        with:
          dockerfile: Dockerfile.backup

      - name: Lint YAML
        run: |
          pipx install yamllint
          yamllint -c .yamllint .

      - name: Scan workflows with zizmor
        run: |
          pipx install zizmor
          zizmor .github/workflows/
```

- [ ] **Step 2: Write the test workflow**

`.github/workflows/test.yml`:

```yaml
---
name: Test

"on":
  pull_request:
  push:
    branches: [main]
  schedule:
    # Nightly, to catch a Project Zomboid update breaking the image before a
    # deployment does.
    - cron: "0 3 * * *"
  workflow_dispatch:

permissions:
  contents: read

jobs:
  unit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1  # v7.0.1
        with:
          persist-credentials: false

      - name: Run bats unit tests
        run: ./tests/run-unit.sh

  smoke:
    runs-on: ubuntu-latest
    needs: unit
    timeout-minutes: 45
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1  # v7.0.1
        with:
          persist-credentials: false

      - name: Free disk space for the Steam download
        run: |
          sudo rm -rf /usr/share/dotnet /opt/ghc /usr/local/share/boost
          df -h /

      - name: Run the smoke test
        env:
          SMOKE_TIMEOUT: "1500"
        run: ./tests/smoke.sh
```

- [ ] **Step 3: Write the release workflow**

`.github/workflows/release.yml`:

```yaml
---
name: Release

"on":
  push:
    branches: [main]
    tags: ["v*"]
  workflow_dispatch:

permissions:
  contents: read
  packages: write

jobs:
  publish:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        include:
          - image: pz-docker-server
            dockerfile: Dockerfile
          - image: pz-docker-server-backup
            dockerfile: Dockerfile.backup
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1  # v7.0.1
        with:
          persist-credentials: false

      - uses: docker/setup-buildx-action@37fe631027851001ddb9b187196cc803df7f5f0e  # v4.3.0

      - name: Build for scanning
        uses: docker/build-push-action@53b7df96c91f9c12dcc8a07bcb9ccacbed38856a  # v7.3.0
        with:
          context: .
          file: ${{ matrix.dockerfile }}
          load: true
          tags: scan-target:${{ matrix.image }}

      - name: Scan with Trivy
        uses: aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25  # v0.36.0
        with:
          image-ref: scan-target:${{ matrix.image }}
          severity: HIGH,CRITICAL
          ignore-unfixed: true
          exit-code: "1"

      - uses: docker/login-action@dbcb813823bdd20940b903addbd779551569679f  # v4.6.0
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Derive tags
        id: meta
        uses: docker/metadata-action@dc802804100637a589fabce1cb79ff13a1411302  # v6.2.0
        with:
          images: ghcr.io/${{ github.repository_owner }}/${{ matrix.image }}
          tags: |
            type=ref,event=branch
            type=semver,pattern={{version}}
            type=semver,pattern={{major}}.{{minor}}
            type=raw,value=latest,enable={{is_default_branch}}

      - name: Build and push
        uses: docker/build-push-action@53b7df96c91f9c12dcc8a07bcb9ccacbed38856a  # v7.3.0
        with:
          context: .
          file: ${{ matrix.dockerfile }}
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
```

Note: `exit-code: "1"` on Trivy is deliberate, and `continue-on-error` is
deliberately absent. A tolerant scanner that silently stops working looks exactly
like a scanner that finds nothing.

- [ ] **Step 4: Write the Renovate configuration**

`renovate.json`:

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": [
    "config:best-practices",
    ":dependencyDashboard"
  ],
  "minimumReleaseAge": "7 days",
  "packageRules": [
    {
      "matchManagers": ["github-actions"],
      "groupName": "github actions"
    },
    {
      "matchManagers": ["dockerfile", "docker-compose"],
      "groupName": "container images"
    }
  ]
}
```

- [ ] **Step 5: Validate the workflows locally**

```bash
yamllint -c .yamllint .github/workflows/
zizmor .github/workflows/
```
Expected: both silent. Fix anything zizmor reports; do not suppress findings.

- [ ] **Step 6: Commit and verify on a pull request**

```bash
git add .github/ renovate.json
git commit -m "ci: add lint, test and release workflows with pinned actions"
git push -u origin HEAD
gh pr create --fill
gh pr checks --watch
```
Expected: `lint` and `unit` pass. `smoke` takes 15–30 minutes. If `smoke` fails on
a Steam timeout, re-run it once before investigating — but never respond by
loosening its assertions.

---

### Task 12: Documentation

**Files:**
- Create: `README.md`, `docs/configuration.md`, `docs/backup-restore.md`, `docs/runbook.md`

**Interfaces:**
- Consumes: the behaviour of every preceding task
- Produces: the public documentation set

- [ ] **Step 1: Write `README.md`**

It must contain, in this order:

1. One-paragraph description: Project Zomboid dedicated server, game files installed into a volume at runtime, no Steam content in the image.
2. Quick start: `git clone`, export `PZ_ADMIN_PASSWORD` and `PZ_RCON_PASSWORD`, `docker compose up -d`, and the explicit warning that the first start takes 5–15 minutes while roughly 3 GB downloads and a world is generated.
3. A ports table: `16261/udp` game, `16262/udp` direct connections, `27015/tcp` RCON internal only, with the sentence that only the two UDP ports need forwarding on a router and RCON must never be exposed.
4. **Memory guidance, stated plainly:** the default `PZ_MAX_RAM` is `4g`, which is a conservative default and not a recommendation. Build 42 with more than two or three players wants 6–8 GB of heap, and the host needs roughly 3 GB of headroom on top because world streaming allocates outside the Java heap. Build 41 runs comfortably at 3–4 GB.
5. Branch switching: `PZ_BRANCH=public` for Build 42, `PZ_BRANCH=legacy41` for Build 41, applied by recreating the container — no rebuild.
6. **The Build 42 mod pitfall:** `WorkshopItems=` takes numeric Workshop IDs; `Mods=` takes the `id=` value from each mod's `mod.info`, and in Build 42 each one needs a leading backslash (`Mods=\ModOne;\ModTwo`). The container warns about missing backslashes and deliberately does not correct them.
7. Link to `docs/configuration.md`, `docs/backup-restore.md`, `docs/runbook.md`.
8. Credits: adapted graceful-shutdown and INI-patching approach from `Danixu/project-zomboid-server-docker` (GPL-3.0), with a link.
9. Licence and the disclaimer that this project is unaffiliated with The Indie Stone and ships no game files.

- [ ] **Step 2: Write `docs/configuration.md`**

A table of every environment variable with default and effect, split into
"Server container" and "Backup sidecar", covering: `PZ_BRANCH`, `PZ_MAX_RAM`,
`UPDATE_ON_START`, `SERVER_NAME`, `ADMIN_USERNAME`, `ADMIN_PASSWORD`,
`SERVER_PASSWORD`, `RCON_PASSWORD`, `RCON_PORT`, `GAME_PORT`, `UDP_PORT`,
`PUBLIC`, `PUBLIC_NAME`, `MAX_PLAYERS`, `MOD_IDS`, `WORKSHOP_IDS`,
`SELF_MANAGED_MODS`, `NOSTEAM`, `MODFOLDERS`, `STEAM_RETRIES`,
`STEAM_RETRY_DELAY`, `TZ`, `BACKUP_INTERVAL`, `BACKUP_KEEP`, `BACKUP_MODE`,
`BACKUP_ON_START`, `BACKUP_SAVE_WAIT`, `NTFY_URL`, `NTFY_TOKEN`.

Followed by a section "What the container does and does not touch": the keys
listed above are patched into `<SERVER_NAME>.ini` on every start; everything
else in that file, all of `<SERVER_NAME>_SandboxVars.lua` and all of
`<SERVER_NAME>_spawnregions.lua` belong to the operator and are never modified.
Editing them means editing the files in the `pz-zomboid` volume and restarting.

Also document that `ADMIN_PASSWORD` is only passed on the very first boot,
because the server writes its command line to the log in clear text, and that
changing it later is done in-game with `/changepwd` or by deleting the world
database.

- [ ] **Step 3: Write `docs/backup-restore.md`**

Cover: what is backed up (`Saves/` and `Server/` from the data volume), the two
modes and when to choose which, how to trigger one by hand
(`docker compose exec pz-backup backup-now`), and a **tested restore procedure**
written as numbered steps: stop the stack, remove the contents of the data
volume, extract the archive back into it, fix ownership to `1000:1000`, start
the stack, verify the world loads.

Add a borgmatic section: set `BACKUP_MODE=dir` and point a borgmatic
`source_directories` entry at the host path behind the `pz-backups` volume,
with the note that Borg deduplicates a directory tree far better than a fresh
compressed archive per run.

State plainly that the restore procedure must be tried once before it is needed.

- [ ] **Step 4: Write `docs/runbook.md`**

Cover: updating the game (recreate the container with `UPDATE_ON_START=true`),
switching branch, changing the heap, adding mods, reading logs
(`docker compose logs -f pz-server` and `/data/zomboid/Logs`), and a
troubleshooting table with at least these entries:

| Symptom | Cause | Fix |
|---|---|---|
| Container restarts before becoming healthy | Heap larger than the host can supply | Lower `PZ_MAX_RAM`, check `free -g` |
| `... is not writable by uid 1000` | Bind mount owned by another user | `chown -R 1000:1000 <host directory>` |
| Mods download but do not load | Missing backslash in `Mods=` on Build 42 | Prefix each id with `\` |
| Players cannot connect from outside | UDP ports not forwarded | Forward `16261/udp` and `16262/udp` |
| World reverted after a crash | Container was killed instead of stopped | Check `stop_grace_period`, restore from a backup |

- [ ] **Step 5: Verify every documented command actually works**

Run each command block from the README and the runbook against the running
stack. Any command that does not work as written is a documentation bug and is
fixed before committing.

- [ ] **Step 6: Commit**

```bash
git add README.md docs/configuration.md docs/backup-restore.md docs/runbook.md
git commit -m "docs: document configuration, backup/restore and operations"
```

---

## After the plan

Once every task is complete and CI is green on `main`, two follow-ups remain,
both of which need Robin's input and must not be done unprompted:

1. **Rename the repository and publish it.** The repository stays private until
   the implementation is finished, and it gets a new name before going public.
   Ask for the name, rename, then update the GHCR image paths in
   `docker-compose.yml`, both workflows and the documentation, and only then
   change the visibility.
2. **Phase 2: Prometheus metrics.** A purpose-built RCON exporter sidecar
   exposing player count, heap usage and uptime, plus a Grafana dashboard. This
   was deliberately deferred so the numbers can be chosen once real usage exists.

## Self-review notes

Checked against the spec, section by section:

- Spec §3 architecture → Tasks 8, 9, 10
- Spec §4 image → Task 8
- Spec §5 lifecycle → Tasks 3, 4, 5, 6
- Spec §6 configuration model, including the Build 42 backslash warning → Tasks 2, 6, 12
- Spec §7 backup sidecar, both modes, all three triggers → Task 10
- Spec §8 health and security, RCON not published → Tasks 7, 9
- Spec §9 CI, all three workflows plus Renovate → Task 11
- Spec §10 defaults → Global Constraints, Tasks 8, 9
- Spec §11 repository layout → File Structure, with the `jvm.sh` deviation recorded
- Spec §12 out of scope → After the plan
- Spec §13 risks → mitigations appear in Tasks 3 (retries), 8 (start period), 11 (nightly run), 12 (memory guidance)
