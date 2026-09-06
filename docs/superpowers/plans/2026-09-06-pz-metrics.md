# Project Zomboid Metrics Implementation Plan

> **Status: executed and released.** All eleven tasks are done; the result shipped
> as [v1.2.0](https://github.com/SWATPeaceKeeper/zomboid-server-docker/releases/tag/v1.2.0)
> on 2026-09-06. The boxes below are ticked because every step was handled, but
> several were handled differently than written:
>
> - **Task 1, populated fixture.** CI cannot make a player join, so the shape of
>   the name lines could not be captured. It is reconstructed from an independent
>   project that parses the same command, and labelled as such in
>   `exporter/testdata/README.md`. The empty case and the manifest are real
>   captures, and both spec assumptions were confirmed.
> - **Task 3, rcontest.** The API sketched here does not exist: `Request()`
>   returns a `*rcon.Packet`, and a reply is written with
>   `rcon.NewPacket(...).WriteTo(c.Conn())`. The library was read before the test
>   was written.
> - **Task 7, base image.** Alpine was replaced by `scratch` after Trivy blocked
>   the release on two HIGH advisories in an OpenSSL the exporter never calls.
>   16 MB, zero findings, nothing to patch. The zone database is embedded via
>   `time/tzdata` as a consequence.
> - **Task 8, how metrics are fetched.** From `pz-backup` rather than from inside
>   the exporter, which has no shell on `scratch`. That also proves the exporter
>   is reachable over the network, the way Prometheus reaches it.
> - **Task 8, `--build`.** Discovered mid-execution: with both `image:` and
>   `build:` set, `docker compose up -d` pulls the published image, so the stack
>   test had been verifying the last release instead of the code. Forced to build.
> - **Task 9, metric name.** `jvm_memory_used_bytes`, not `jvm_memory_bytes_used`;
>   the Prometheus Java client renamed it at 1.0. The agent worked all along.
>   The fallback of downloading the jar at runtime was measured against and left
>   unused: 530 MB to 550 MB.
> - **Task 10, dashboard.** Written by hand rather than exported from Grafana,
>   then verified by importing it into a real Grafana against a real Prometheus.
>   That caught a `{{pool}}` legend referring to a label that does not exist.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose player activity, backup health, server reachability and — optionally — JVM metrics as Prometheus metrics, so a quiet server or a silently failing backup becomes visible before anyone needs either.

**Architecture:** A third container, `pz-exporter`, written in Go. It reads only: RCON queries against the server plus two read-only volume mounts. The backup sidecar gains a small status file so failures are visible at all, since files alone only show what exists. JVM metrics come from the standard Prometheus JMX Java agent, opt-in and off by default, rather than from hand-written metric code.

**Tech Stack:** Go 1.27, `prometheus/client_golang` v1.24.x, `gorcon/rcon` v1.4.x, `prometheus/jmx_exporter` 1.6.0, Docker, bats, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-06-pz-metrics-design.md`

## Global Constraints

- **Go module path:** `github.com/SWATPeaceKeeper/zomboid-server-docker/exporter`, `go 1.27`.
- **Builder image, pinned:** `golang:1.27-trixie@sha256:9baa6b4187bbb98d240372a8a235ac0bb6b5ddd52bba1431dc2f7c0705862728`
- **Exporter runtime image, pinned:** `alpine:3@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b` — small, and it keeps a shell for debugging, which `scratch` would not.
- **JMX agent:** `jmx_prometheus_javaagent-1.6.0.jar`, SHA-256 `a95983fd96e865d2bcdf911cc500e7c82808c27ab9fd226bf96732b6c3d8c46e`, from `https://github.com/prometheus/jmx_exporter/releases/download/1.6.0/`. **10.7 MB** — see Task 9, which measures the cost before committing to baking it in.
- **`gorcon/rcon`** module path is `github.com/gorcon/rcon`; it ships an `rcontest` package for in-process fake servers.
- **All containers run as UID/GID 1000** with no root phase at runtime.
- **Every shell script** starts with `#!/usr/bin/env bash` and `set -euo pipefail`, passes `shellcheck` and `shfmt -i 2`.
- **Go code** is formatted with `gofmt` and passes `go vet` with zero output. Both run in CI.
- **Metric names are the public interface.** Once released they are not renamed without a major version. The exact set is in spec §4.
- **Ports:** exporter `9401`, JMX agent `9404`. Neither is published to the host by the default Compose file.
- **Do not run a Project Zomboid server on the development laptop.** It has 7.6 GB of RAM and a Build 42 server at the default heap has already caused an OOM there. All full-stack verification happens in CI.
- **Never predict image sizes.** Measure them and record the measurement.

## File Structure

| File | Responsibility |
|---|---|
| `exporter/go.mod`, `go.sum` | Module definition |
| `exporter/main.go` | Config from environment, HTTP server, wiring |
| `exporter/internal/players/players.go` | RCON client and parsing of the `players` output |
| `exporter/internal/backups/backups.go` | Reading the status file and counting archives |
| `exporter/internal/manifest/manifest.go` | Reading the Steam build id |
| `exporter/internal/collector/collector.go` | Prometheus collector over the three sources |
| `exporter/testdata/` | Captured real output used as test fixtures |
| `Dockerfile.exporter` | Two-stage build |
| `docker-compose.yml` | Adds the `pz-exporter` service |
| `docker-compose.monitoring.yml` | Overlay attaching to an external `monitoring` network |
| `grafana/pz-dashboard.json` | Dashboard |
| `scripts/backup/backup-now.sh` | Also writes the status file |
| `scripts/lib/jvm.sh` | Also adds the JMX agent when enabled |
| `tests/stack-smoke.sh` | Also asserts the exporter answers |

---

### Task 1: Capture what the server actually says

Spec §9 lists two assumptions this design rests on and forbids building on them
unverified. This task replaces both with captured evidence. It produces no
production code — its deliverable is fixtures and a decision.

**Files:**
- Create: `exporter/testdata/players_empty.txt`, `exporter/testdata/players_populated.txt`, `exporter/testdata/appmanifest_380870.acf`
- Modify: `tests/stack-smoke.sh`

**Interfaces:**
- Consumes: nothing
- Produces: three fixture files. Every parser in Tasks 3 and 5 is written against these, not against any format assumed in this plan.

- [x] **Step 1: Add a capture step to the stack smoke test**

In `tests/stack-smoke.sh`, directly after the `==> Healthy` line, insert:

```bash
echo "==> CAPTURE: rcon players (no players connected)"
echo "----8<---- players_empty ----8<----"
docker compose exec -T pz-server \
  rcon -a "127.0.0.1:27015" -p "${PZ_RCON_PASSWORD}" players || true
echo "----8<---- end ----8<----"

echo "==> CAPTURE: steam app manifest"
echo "----8<---- appmanifest ----8<----"
docker compose exec -T pz-server \
  sh -c 'cat /data/server/steamapps/appmanifest_380870.acf 2>&1 | head -40' || true
echo "----8<---- end ----8<----"
```

- [x] **Step 2: Push and let CI run it**

```bash
git add tests/stack-smoke.sh
git commit -m "test: temporarily capture rcon and manifest output"
git push
gh run watch
```

- [x] **Step 3: Read the captured output out of the CI log**

```bash
gh run view --job smoke --log | sed -n '/----8<---- players_empty/,/----8<---- end/p'
gh run view --job smoke --log | sed -n '/----8<---- appmanifest/,/----8<---- end/p'
```

- [x] **Step 4: Save the captures as fixtures**

Write the `players` output verbatim to `exporter/testdata/players_empty.txt` and
the manifest to `exporter/testdata/appmanifest_380870.acf`, stripping only the CI
log's timestamp prefix.

For `exporter/testdata/players_populated.txt`, take the empty-case output and add
player lines in exactly the shape the real one uses. If the empty case gives no
hint of that shape (for example it prints only a bare count), note this in the
file as a comment and treat the populated case as unverified until someone joins
a real server.

- [x] **Step 5: Record the verdict on both assumptions**

Append to `docs/superpowers/specs/2026-09-06-pz-metrics-design.md` under §9, one
line per assumption, stating what was found. If the manifest has no `buildid`
key, write that down and **drop `pz_server_info` from the plan** — Task 5 is then
skipped entirely and nothing else changes.

- [x] **Step 6: Remove the capture step and commit**

Revert the change to `tests/stack-smoke.sh` from Step 1; it has served its
purpose and would otherwise print noise on every run.

```bash
git add exporter/testdata/ tests/stack-smoke.sh docs/superpowers/specs/
git commit -m "test: capture real rcon and manifest output as fixtures"
```

---

### Task 2: Backup status file

The exporter cannot see a failed backup by looking at files: files show what
exists, not what is missing. The sidecar records each outcome instead.

**Files:**
- Modify: `scripts/backup/backup-now.sh`
- Test: `tests/unit/backup.bats`

**Interfaces:**
- Consumes: `backup_create`, `backup_rotate`, `backup_notify` from `scripts/backup/lib/backup.sh`
- Produces: `${BACKUP_DIR}/.status`, a file of `key=value` lines with keys `timestamp` (Unix seconds), `status` (`ok`, `failed` or `skipped`), `archive` (path, empty unless `ok`) and `bytes` (integer, `0` unless `ok`). Written after every run, including failures.

- [x] **Step 1: Write the failing tests**

Append to `tests/unit/backup.bats`:

```bash
@test "backup-now writes a status file on success" {
  PZ_DATA_DIR="${DATA_DIR}" BACKUP_DIR="${BACKUP_DIR}" BACKUP_MODE="tar" \
    run "${REPO_ROOT}/scripts/backup/backup-now.sh"
  [ "$status" -eq 0 ]

  [ -f "${BACKUP_DIR}/.status" ]
  grep -q '^status=ok$' "${BACKUP_DIR}/.status"
  grep -qE '^timestamp=[0-9]+$' "${BACKUP_DIR}/.status"
  grep -qE '^bytes=[0-9]+$' "${BACKUP_DIR}/.status"
  grep -qE '^archive=.*\.tar\.zst$' "${BACKUP_DIR}/.status"
}

@test "backup-now records a skip when there is no world yet" {
  rm -rf "${DATA_DIR}/Saves"
  PZ_DATA_DIR="${DATA_DIR}" BACKUP_DIR="${BACKUP_DIR}" \
    run "${REPO_ROOT}/scripts/backup/backup-now.sh"
  [ "$status" -eq 2 ]
  grep -q '^status=skipped$' "${BACKUP_DIR}/.status"
  grep -q '^bytes=0$' "${BACKUP_DIR}/.status"
}

@test "backup-now records a failure when the archiver fails" {
  mkdir -p "${TEST_TMP}/bin"
  printf '#!/usr/bin/env bash\nexit 2\n' >"${TEST_TMP}/bin/tar"
  chmod +x "${TEST_TMP}/bin/tar"
  # Each bats test runs in its own subshell, so shadowing tar here cannot leak
  # into another test. That locality is the point, not an accident.
  # shellcheck disable=SC2030,SC2031
  PATH="${TEST_TMP}/bin:${PATH}"

  PZ_DATA_DIR="${DATA_DIR}" BACKUP_DIR="${BACKUP_DIR}" BACKUP_MODE="tar" \
    run "${REPO_ROOT}/scripts/backup/backup-now.sh"
  [ "$status" -eq 1 ]
  grep -q '^status=failed$' "${BACKUP_DIR}/.status"
}

@test "backup_rotate does not delete the status file" {
  touch "${BACKUP_DIR}/.status"
  touch "${BACKUP_DIR}/pz-20260101-000000.tar.zst"
  backup_rotate "${BACKUP_DIR}" 0
  [ -f "${BACKUP_DIR}/.status" ]
}
```

- [x] **Step 2: Run them and watch them fail**

Run: `./tests/run-unit.sh`
Expected: the four new tests fail; `.status` does not exist yet.

- [x] **Step 3: Implement**

In `scripts/backup/backup-now.sh`, add above `main()`:

```bash
# Records the outcome of this run where the exporter can see it. Written for
# every outcome, because "no status file changed since yesterday" and "yesterday's
# backup failed" have to be distinguishable.
write_status() {
  local state="$1" archive="${2:-}" bytes="${3:-0}"
  local status_file="${BACKUP_DIR}/.status"
  mkdir -p "${BACKUP_DIR}"
  {
    printf 'timestamp=%s\n' "$(date -u +%s)"
    printf 'status=%s\n' "${state}"
    printf 'archive=%s\n' "${archive}"
    printf 'bytes=%s\n' "${bytes}"
  } >"${status_file}.tmp"
  # Renamed into place so a reader never sees a half-written file.
  mv "${status_file}.tmp" "${status_file}"
}
```

Replace `main()` with:

```bash
main() {
  local archive status=0 bytes=0
  save_world
  archive="$(backup_create "${PZ_DATA_DIR}" "${BACKUP_DIR}" "${BACKUP_MODE}")" || status=$?

  if [ "${status}" -eq 2 ]; then
    write_status "skipped"
    return 2
  fi
  if [ "${status}" -ne 0 ]; then
    write_status "failed"
    backup_notify "failure" "Backup failed; see the container log."
    return 1
  fi

  bytes="$(du -sb "${archive}" 2>/dev/null | cut -f1)"
  write_status "ok" "${archive}" "${bytes:-0}"
  log_info "Created ${archive}"
  backup_rotate "${BACKUP_DIR}" "${BACKUP_KEEP}"
}
```

`backup_rotate` already only matches `pz-*`, so `.status` is untouched by it —
the fourth test above locks that in.

- [x] **Step 4: Run the tests again**

Run: `./tests/run-unit.sh`
Expected: PASS, all tests.

- [x] **Step 5: Lint and commit**

```bash
shellcheck scripts/backup/backup-now.sh
shfmt -i 2 -d scripts/
git add scripts/backup/backup-now.sh tests/unit/backup.bats
git commit -m "feat: record each backup outcome in a status file"
```

---

### Task 3: Go module, CI wiring and the players parser

**Files:**
- Create: `exporter/go.mod`, `exporter/internal/players/players.go`, `exporter/internal/players/players_test.go`
- Modify: `.github/workflows/lint.yml`, `.github/workflows/test.yml`, `.gitignore`

**Interfaces:**
- Consumes: the fixtures from Task 1
- Produces:
  - `type Snapshot struct { Count int; Names []string }`
  - `func Parse(raw string) (Snapshot, error)` — parses the raw `players` output. Returns an error for empty input.
  - `type Client struct{ ... }`
  - `func NewClient(addr, password string, timeout time.Duration) *Client`
  - `func (c *Client) Query() (Snapshot, error)` — dials RCON, runs `players`, parses the reply.

- [x] **Step 1: Create the module**

```bash
mkdir -p exporter/internal/players
cd exporter
go mod init github.com/SWATPeaceKeeper/zomboid-server-docker/exporter
go get github.com/gorcon/rcon@v1.4.0
go get github.com/prometheus/client_golang@v1.24.1
cd ..
```

Append to `.gitignore`:

```gitignore
/exporter/exporter
```

- [x] **Step 2: Write the failing tests**

`exporter/internal/players/players_test.go`:

```go
package players

import (
	"os"
	"path/filepath"
	"testing"
)

// The fixtures are captured from a real server (see the plan, Task 1). They are
// the source of truth for this format, not anything written down here: Project
// Zomboid does not document it and has changed it between builds.
func fixture(t *testing.T, name string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("..", "..", "testdata", name))
	if err != nil {
		t.Fatalf("reading fixture %s: %v", name, err)
	}
	return string(b)
}

func TestParseEmptyServer(t *testing.T) {
	got, err := Parse(fixture(t, "players_empty.txt"))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.Count != 0 {
		t.Errorf("Count = %d, want 0", got.Count)
	}
	if len(got.Names) != 0 {
		t.Errorf("Names = %v, want empty", got.Names)
	}
}

func TestParsePopulatedServer(t *testing.T) {
	got, err := Parse(fixture(t, "players_populated.txt"))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.Count != len(got.Names) {
		t.Errorf("Count = %d but got %d names: %v", got.Count, len(got.Names), got.Names)
	}
	if got.Count == 0 {
		t.Error("fixture is supposed to have players in it")
	}
}

func TestParseRejectsEmptyInput(t *testing.T) {
	if _, err := Parse("   \n\n"); err == nil {
		t.Error("expected an error for empty input, got nil")
	}
}

func TestParseHandlesCRLF(t *testing.T) {
	got, err := Parse("Players connected (1):\r\n-Bob\r\n")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got.Names) != 1 || got.Names[0] != "Bob" {
		t.Errorf("Names = %v, want [Bob]", got.Names)
	}
}

func TestParseFallsBackToCountingNames(t *testing.T) {
	// No header with a number in it; the names are all there is to go on.
	got, err := Parse("-Bob\n-Alice\n")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.Count != 2 {
		t.Errorf("Count = %d, want 2", got.Count)
	}
}
```

- [x] **Step 3: Run them and watch them fail**

Run: `cd exporter && go test ./... ; cd ..`
Expected: FAIL — `undefined: Parse`.

- [x] **Step 4: Implement the parser**

`exporter/internal/players/players.go`:

```go
// Package players queries the Project Zomboid server for its player list.
package players

import (
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/gorcon/rcon"
)

// Snapshot is the result of one `players` query.
type Snapshot struct {
	Count int
	Names []string
}

var countPattern = regexp.MustCompile(`\((\d+)\)`)

// Parse turns the raw text of the `players` console command into a Snapshot.
//
// Project Zomboid does not document this format and has changed neighbouring
// output between builds, so this is deliberately forgiving. It takes the count
// from a header line when one carries a number in brackets, and otherwise counts
// the names it found. Lines beginning with "-" are names.
func Parse(raw string) (Snapshot, error) {
	if strings.TrimSpace(raw) == "" {
		return Snapshot{}, errors.New("empty response from the players command")
	}

	var snap Snapshot
	haveHeaderCount := false

	for _, line := range strings.Split(strings.ReplaceAll(raw, "\r\n", "\n"), "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			continue
		}

		if strings.HasPrefix(trimmed, "-") {
			name := strings.TrimSpace(strings.TrimPrefix(trimmed, "-"))
			if name != "" {
				snap.Names = append(snap.Names, name)
			}
			continue
		}

		if !haveHeaderCount {
			if m := countPattern.FindStringSubmatch(trimmed); m != nil {
				n, err := strconv.Atoi(m[1])
				if err != nil {
					return Snapshot{}, fmt.Errorf("parsing player count from %q: %w", trimmed, err)
				}
				snap.Count = n
				haveHeaderCount = true
			}
		}
	}

	if !haveHeaderCount {
		snap.Count = len(snap.Names)
	}
	return snap, nil
}

// Client queries one server over RCON.
type Client struct {
	addr     string
	password string
	timeout  time.Duration
}

func NewClient(addr, password string, timeout time.Duration) *Client {
	return &Client{addr: addr, password: password, timeout: timeout}
}

// Query opens a connection, asks for the player list and closes again. A
// short-lived connection per scrape is deliberate: a pooled one would have to
// survive server restarts, and `players` is cheap.
func (c *Client) Query() (Snapshot, error) {
	conn, err := rcon.Dial(c.addr, c.password,
		rcon.SetDialTimeout(c.timeout),
		rcon.SetDeadline(c.timeout),
	)
	if err != nil {
		return Snapshot{}, fmt.Errorf("connecting to %s: %w", c.addr, err)
	}
	defer conn.Close()

	raw, err := conn.Execute("players")
	if err != nil {
		return Snapshot{}, fmt.Errorf("running the players command: %w", err)
	}
	return Parse(raw)
}
```

- [x] **Step 5: Run the tests again**

Run: `cd exporter && go test ./... ; cd ..`
Expected: PASS. If `TestParseEmptyServer` or `TestParsePopulatedServer` fails,
**the fixture is right and this parser is wrong** — adjust `Parse`, never the
fixture.

- [x] **Step 6: Add a test against a fake RCON server**

Append to `players_test.go`:

```go
func TestClientQueryAgainstFakeServer(t *testing.T) {
	server := rcontest.NewServer(
		rcontest.SetSettings(rcontest.Settings{Password: "secret"}),
		rcontest.SetCommandHandler(func(c *rcontest.Context) {
			if c.Request() != "players" {
				t.Errorf("unexpected command %q", c.Request())
			}
			c.WriteResponse("Players connected (1):\n-Bob")
		}),
	)
	defer server.Close()

	got, err := NewClient(server.Addr(), "secret", 2*time.Second).Query()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.Count != 1 || len(got.Names) != 1 || got.Names[0] != "Bob" {
		t.Errorf("got %+v, want 1 player named Bob", got)
	}
}

func TestClientQueryFailsOnWrongPassword(t *testing.T) {
	server := rcontest.NewServer(
		rcontest.SetSettings(rcontest.Settings{Password: "secret"}),
	)
	defer server.Close()

	if _, err := NewClient(server.Addr(), "wrong", 2*time.Second).Query(); err == nil {
		t.Error("expected an authentication error, got nil")
	}
}
```

Add `"github.com/gorcon/rcon/rcontest"` to the test file's imports.

Run: `cd exporter && go test ./... ; cd ..`
Expected: PASS. If the `rcontest` API differs from the calls above, adapt these
tests to the version in `go.sum` — check with
`go doc github.com/gorcon/rcon/rcontest`.

- [x] **Step 7: Wire Go into CI**

In `.github/workflows/lint.yml`, add before the yamllint step:

```yaml
      - name: Check Go formatting and vet
        run: |
          docker run --rm -v "${PWD}/exporter:/src" -w /src \
            golang:1.27-trixie@sha256:9baa6b4187bbb98d240372a8a235ac0bb6b5ddd52bba1431dc2f7c0705862728 \
            sh -c 'test -z "$(gofmt -l .)" || { gofmt -d .; exit 1; }; go vet ./...'
```

In `.github/workflows/test.yml`, add to the `unit` job after the bats step:

```yaml
      - name: Run Go tests
        run: |
          docker run --rm -v "${PWD}/exporter:/src" -w /src \
            golang:1.27-trixie@sha256:9baa6b4187bbb98d240372a8a235ac0bb6b5ddd52bba1431dc2f7c0705862728 \
            go test ./...
```

Using the pinned builder image rather than `actions/setup-go` keeps the toolchain
identical to the one the release build uses.

- [x] **Step 8: Verify and commit**

```bash
docker run --rm -v "${PWD}/exporter:/src" -w /src \
  golang:1.27-trixie sh -c 'gofmt -l . && go vet ./... && go test ./...'
yamllint -c .yamllint .github/workflows/
zizmor --persona=regular .github/workflows/
git add exporter/ .github/workflows/ .gitignore
git commit -m "feat: add go module and the rcon players parser"
```

---

### Task 4: Backup status parser

**Files:**
- Create: `exporter/internal/backups/backups.go`, `exporter/internal/backups/backups_test.go`

**Interfaces:**
- Consumes: the `.status` format from Task 2
- Produces:
  - `type Status struct { Timestamp time.Time; State string; Archive string; Bytes int64 }`
  - `func ParseStatus(raw string) (Status, error)`
  - `func ReadStatus(dir string) (Status, error)` — reads `<dir>/.status`
  - `func CountArchives(dir string) (int, error)` — counts entries matching `pz-*`

- [x] **Step 1: Write the failing tests**

`exporter/internal/backups/backups_test.go`:

```go
package backups

import (
	"os"
	"path/filepath"
	"testing"
)

const okStatus = `timestamp=1788700000
status=ok
archive=/data/backups/pz-20260906-115955.tar.zst
bytes=48291043
`

func TestParseStatusOK(t *testing.T) {
	got, err := ParseStatus(okStatus)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.State != "ok" {
		t.Errorf("State = %q, want ok", got.State)
	}
	if got.Bytes != 48291043 {
		t.Errorf("Bytes = %d, want 48291043", got.Bytes)
	}
	if got.Timestamp.Unix() != 1788700000 {
		t.Errorf("Timestamp = %v, want unix 1788700000", got.Timestamp)
	}
	if got.Archive != "/data/backups/pz-20260906-115955.tar.zst" {
		t.Errorf("Archive = %q", got.Archive)
	}
}

func TestParseStatusSkipped(t *testing.T) {
	got, err := ParseStatus("timestamp=1\nstatus=skipped\narchive=\nbytes=0\n")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.State != "skipped" {
		t.Errorf("State = %q, want skipped", got.State)
	}
	if got.Bytes != 0 {
		t.Errorf("Bytes = %d, want 0", got.Bytes)
	}
}

func TestParseStatusRejectsGarbage(t *testing.T) {
	for _, in := range []string{"", "not a status file", "timestamp=abc\nstatus=ok\n"} {
		if _, err := ParseStatus(in); err == nil {
			t.Errorf("expected an error for %q, got nil", in)
		}
	}
}

func TestParseStatusIgnoresUnknownKeys(t *testing.T) {
	// A newer sidecar may add fields. An older exporter must not choke on them.
	got, err := ParseStatus(okStatus + "duration_seconds=12\n")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.State != "ok" {
		t.Errorf("State = %q, want ok", got.State)
	}
}

func TestReadStatusMissingFile(t *testing.T) {
	if _, err := ReadStatus(t.TempDir()); err == nil {
		t.Error("expected an error when .status is absent, got nil")
	}
}

func TestCountArchives(t *testing.T) {
	dir := t.TempDir()
	for _, n := range []string{"pz-1.tar.zst", "pz-2.tar.zst", ".status", "README"} {
		if err := os.WriteFile(filepath.Join(dir, n), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Mkdir(filepath.Join(dir, "pz-3"), 0o755); err != nil {
		t.Fatal(err)
	}

	got, err := CountArchives(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != 3 {
		t.Errorf("CountArchives = %d, want 3 (two archives and one directory backup)", got)
	}
}
```

- [x] **Step 2: Run them and watch them fail**

Run: `cd exporter && go test ./internal/backups/ ; cd ..`
Expected: FAIL — `undefined: ParseStatus`.

- [x] **Step 3: Implement**

`exporter/internal/backups/backups.go`:

```go
// Package backups reads what the backup sidecar recorded about its last run.
package backups

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Status is one line of history: what the sidecar did last, and how it went.
type Status struct {
	Timestamp time.Time
	State     string // ok, failed or skipped
	Archive   string
	Bytes     int64
}

// ParseStatus reads the key=value file the sidecar writes. Unknown keys are
// ignored on purpose, so a newer sidecar can add fields without breaking an
// exporter that has not been updated yet.
func ParseStatus(raw string) (Status, error) {
	fields := map[string]string{}
	for _, line := range strings.Split(raw, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		key, value, found := strings.Cut(line, "=")
		if !found {
			continue
		}
		fields[strings.TrimSpace(key)] = strings.TrimSpace(value)
	}

	state, ok := fields["status"]
	if !ok {
		return Status{}, fmt.Errorf("no status key in %d parsed fields", len(fields))
	}

	seconds, err := strconv.ParseInt(fields["timestamp"], 10, 64)
	if err != nil {
		return Status{}, fmt.Errorf("parsing timestamp %q: %w", fields["timestamp"], err)
	}

	// An absent or unparsable size is zero rather than an error: the size is
	// decoration, the outcome is not.
	bytes, _ := strconv.ParseInt(fields["bytes"], 10, 64)

	return Status{
		Timestamp: time.Unix(seconds, 0).UTC(),
		State:     state,
		Archive:   fields["archive"],
		Bytes:     bytes,
	}, nil
}

func ReadStatus(dir string) (Status, error) {
	path := filepath.Join(dir, ".status")
	raw, err := os.ReadFile(path)
	if err != nil {
		return Status{}, fmt.Errorf("reading %s: %w", path, err)
	}
	return ParseStatus(string(raw))
}

// CountArchives counts backups, which are both tar archives and directories
// depending on BACKUP_MODE.
func CountArchives(dir string) (int, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return 0, fmt.Errorf("reading %s: %w", dir, err)
	}
	count := 0
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), "pz-") {
			count++
		}
	}
	return count, nil
}
```

- [x] **Step 4: Run the tests again**

Run: `cd exporter && go test ./... ; cd ..`
Expected: PASS

- [x] **Step 5: Commit**

```bash
git add exporter/internal/backups/
git commit -m "feat: read the backup status file"
```

---

### Task 5: Steam build id

**Skip this task entirely if Task 1 found no `buildid` key in the manifest.** In
that case, remove `pz_server_info` from Task 6 as well; nothing else depends on
it.

**Files:**
- Create: `exporter/internal/manifest/manifest.go`, `exporter/internal/manifest/manifest_test.go`

**Interfaces:**
- Consumes: `exporter/testdata/appmanifest_380870.acf` from Task 1
- Produces: `func BuildID(serverDir string) (string, error)` — reads
  `<serverDir>/steamapps/appmanifest_380870.acf` and returns the `buildid` value.

- [x] **Step 1: Write the failing tests**

`exporter/internal/manifest/manifest_test.go`:

```go
package manifest

import (
	"os"
	"path/filepath"
	"testing"
)

func TestBuildIDFromCapturedManifest(t *testing.T) {
	dir := t.TempDir()
	steamapps := filepath.Join(dir, "steamapps")
	if err := os.MkdirAll(steamapps, 0o755); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(filepath.Join("..", "..", "testdata", "appmanifest_380870.acf"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(steamapps, "appmanifest_380870.acf"), raw, 0o644); err != nil {
		t.Fatal(err)
	}

	got, err := BuildID(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got == "" {
		t.Error("BuildID is empty; the captured manifest was supposed to contain one")
	}
	for _, r := range got {
		if r < '0' || r > '9' {
			t.Errorf("BuildID = %q, want digits only", got)
			break
		}
	}
}

func TestBuildIDMissingFile(t *testing.T) {
	if _, err := BuildID(t.TempDir()); err == nil {
		t.Error("expected an error when the manifest is absent, got nil")
	}
}

func TestBuildIDMissingKey(t *testing.T) {
	dir := t.TempDir()
	steamapps := filepath.Join(dir, "steamapps")
	if err := os.MkdirAll(steamapps, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(steamapps, "appmanifest_380870.acf"),
		[]byte("\"AppState\"\n{\n\t\"appid\"\t\"380870\"\n}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := BuildID(dir); err == nil {
		t.Error("expected an error when buildid is absent, got nil")
	}
}
```

- [x] **Step 2: Run them and watch them fail**

Run: `cd exporter && go test ./internal/manifest/ ; cd ..`
Expected: FAIL — `undefined: BuildID`.

- [x] **Step 3: Implement**

`exporter/internal/manifest/manifest.go`:

```go
// Package manifest reads the Steam application manifest that SteamCMD writes
// next to the installed game.
package manifest

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
)

// The manifest is Valve's key-value format: a quoted key, whitespace, a quoted
// value. Only one field is needed, so a full parser would be more machinery than
// the job deserves.
var buildIDPattern = regexp.MustCompile(`"buildid"\s+"(\d+)"`)

func BuildID(serverDir string) (string, error) {
	path := filepath.Join(serverDir, "steamapps", "appmanifest_380870.acf")
	raw, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("reading %s: %w", path, err)
	}
	m := buildIDPattern.FindSubmatch(raw)
	if m == nil {
		return "", fmt.Errorf("no buildid field in %s", path)
	}
	return string(m[1]), nil
}
```

- [x] **Step 4: Run the tests again**

Run: `cd exporter && go test ./... ; cd ..`
Expected: PASS

- [x] **Step 5: Commit**

```bash
git add exporter/internal/manifest/
git commit -m "feat: read the steam build id from the app manifest"
```

---

### Task 6: The Prometheus collector

**Files:**
- Create: `exporter/internal/collector/collector.go`, `exporter/internal/collector/collector_test.go`

**Interfaces:**
- Consumes: `players.Snapshot`, `backups.Status`, `manifest.BuildID`
- Produces:
  - `type PlayerSource interface { Query() (players.Snapshot, error) }`
  - `type BackupSource interface { Status() (backups.Status, error); Count() (int, error) }`
  - `type VersionSource interface { BuildID() (string, error) }`
  - `type Options struct { ExportPlayerNames bool }`
  - `func New(p PlayerSource, b BackupSource, v VersionSource, o Options) *Collector`
  - `Collector` implements `prometheus.Collector`.

- [x] **Step 1: Write the failing tests**

`exporter/internal/collector/collector_test.go`:

```go
package collector

import (
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/SWATPeaceKeeper/zomboid-server-docker/exporter/internal/backups"
	"github.com/SWATPeaceKeeper/zomboid-server-docker/exporter/internal/players"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/testutil"
)

type stubPlayers struct {
	snap players.Snapshot
	err  error
}

func (s stubPlayers) Query() (players.Snapshot, error) { return s.snap, s.err }

type stubBackups struct {
	status backups.Status
	count  int
	err    error
}

func (s stubBackups) Status() (backups.Status, error) { return s.status, s.err }
func (s stubBackups) Count() (int, error)             { return s.count, s.err }

type stubVersion struct {
	id  string
	err error
}

func (s stubVersion) BuildID() (string, error) { return s.id, s.err }

func gather(t *testing.T, c *Collector) string {
	t.Helper()
	reg := prometheus.NewPedanticRegistry()
	if err := reg.Register(c); err != nil {
		t.Fatalf("registering collector: %v", err)
	}
	families, err := reg.Gather()
	if err != nil {
		t.Fatalf("gathering: %v", err)
	}
	var sb strings.Builder
	for _, f := range families {
		sb.WriteString(f.GetName())
		sb.WriteString("\n")
	}
	_ = testutil.CollectAndCount(c)
	return sb.String()
}

func healthy() *Collector {
	return New(
		stubPlayers{snap: players.Snapshot{Count: 2, Names: []string{"Bob", "Alice"}}},
		stubBackups{status: backups.Status{State: "ok", Timestamp: time.Unix(100, 0), Bytes: 42}, count: 3},
		stubVersion{id: "18927456"},
		Options{ExportPlayerNames: true},
	)
}

func TestHealthyServerReportsUpAndPlayers(t *testing.T) {
	c := healthy()
	expected := `
# HELP pz_players_online Number of players currently connected.
# TYPE pz_players_online gauge
pz_players_online 2
`
	if err := testutil.CollectAndCompare(c, strings.NewReader(expected), "pz_players_online"); err != nil {
		t.Error(err)
	}
	if got := testutil.ToFloat64(c.up); got != 1 {
		t.Errorf("pz_up = %v, want 1", got)
	}
}

func TestRconFailureOmitsPlayerMetricsRatherThanReportingZero(t *testing.T) {
	// A server that is down is not a server with nobody on it. Reporting zero
	// would make an outage look like a quiet evening on the dashboard.
	c := New(
		stubPlayers{err: errors.New("connection refused")},
		stubBackups{status: backups.Status{State: "ok", Timestamp: time.Unix(100, 0)}, count: 1},
		stubVersion{id: "1"},
		Options{ExportPlayerNames: true},
	)
	if got := testutil.CollectAndCount(c, "pz_players_online"); got != 0 {
		t.Errorf("pz_players_online was collected %d times, want 0", got)
	}
	if got := testutil.ToFloat64(c.up); got != 0 {
		t.Errorf("pz_up = %v, want 0", got)
	}
}

func TestBackupFailureDoesNotBlankTheOtherSources(t *testing.T) {
	c := New(
		stubPlayers{snap: players.Snapshot{Count: 1, Names: []string{"Bob"}}},
		stubBackups{err: errors.New("no status file")},
		stubVersion{id: "1"},
		Options{ExportPlayerNames: true},
	)
	if got := testutil.CollectAndCount(c, "pz_players_online"); got != 1 {
		t.Errorf("pz_players_online was collected %d times, want 1", got)
	}
	if got := testutil.CollectAndCount(c, "pz_backup_last_run_timestamp_seconds"); got != 0 {
		t.Errorf("backup metric was collected despite the source failing")
	}
}

func TestPlayerNamesCanBeSuppressed(t *testing.T) {
	c := New(
		stubPlayers{snap: players.Snapshot{Count: 2, Names: []string{"Bob", "Alice"}}},
		stubBackups{status: backups.Status{State: "ok", Timestamp: time.Unix(100, 0)}, count: 1},
		stubVersion{id: "1"},
		Options{ExportPlayerNames: false},
	)
	if got := testutil.CollectAndCount(c, "pz_player_info"); got != 0 {
		t.Errorf("pz_player_info was collected %d times, want 0", got)
	}
	if got := testutil.CollectAndCount(c, "pz_players_online"); got != 1 {
		t.Errorf("pz_players_online should still be collected, got %d", got)
	}
}

func TestErrorsAreCountedPerSource(t *testing.T) {
	c := New(
		stubPlayers{err: errors.New("boom")},
		stubBackups{err: errors.New("boom")},
		stubVersion{err: errors.New("boom")},
		Options{},
	)
	_ = testutil.CollectAndCount(c)
	for _, source := range []string{"rcon", "backups", "manifest"} {
		if got := testutil.ToFloat64(c.errors.WithLabelValues(source)); got != 1 {
			t.Errorf("pz_scrape_errors_total{source=%q} = %v, want 1", source, got)
		}
	}
}

func TestCollectorPassesPedanticRegistration(t *testing.T) {
	if out := gather(t, healthy()); out == "" {
		t.Error("no metric families were produced")
	}
}
```

- [x] **Step 2: Run them and watch them fail**

Run: `cd exporter && go test ./internal/collector/ ; cd ..`
Expected: FAIL — `undefined: New`.

- [x] **Step 3: Implement**

`exporter/internal/collector/collector.go`:

```go
// Package collector turns the three data sources into Prometheus metrics.
package collector

import (
	"github.com/SWATPeaceKeeper/zomboid-server-docker/exporter/internal/backups"
	"github.com/SWATPeaceKeeper/zomboid-server-docker/exporter/internal/players"
	"github.com/prometheus/client_golang/prometheus"
)

type PlayerSource interface {
	Query() (players.Snapshot, error)
}

type BackupSource interface {
	Status() (backups.Status, error)
	Count() (int, error)
}

type VersionSource interface {
	BuildID() (string, error)
}

type Options struct {
	// ExportPlayerNames adds one series per connected player. Harmless for a
	// group of friends; on a busy public server the series count grows with
	// every player who has ever joined.
	ExportPlayerNames bool
}

type Collector struct {
	playerSource  PlayerSource
	backupSource  BackupSource
	versionSource VersionSource
	opts          Options

	up     prometheus.Gauge
	errors *prometheus.CounterVec

	playersOnline *prometheus.Desc
	playerInfo    *prometheus.Desc
	serverInfo    *prometheus.Desc
	backupLastRun *prometheus.Desc
	backupLastOK  *prometheus.Desc
	backupBytes   *prometheus.Desc
	backupCount   *prometheus.Desc
}

func New(p PlayerSource, b BackupSource, v VersionSource, o Options) *Collector {
	return &Collector{
		playerSource:  p,
		backupSource:  b,
		versionSource: v,
		opts:          o,
		up: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "pz_up",
			Help: "1 if the server answered RCON on this scrape, 0 otherwise.",
		}),
		errors: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "pz_scrape_errors_total",
			Help: "Failed collections, by source.",
		}, []string{"source"}),
		playersOnline: prometheus.NewDesc(
			"pz_players_online", "Number of players currently connected.", nil, nil),
		playerInfo: prometheus.NewDesc(
			"pz_player_info", "Constant 1 for each connected player.", []string{"name"}, nil),
		serverInfo: prometheus.NewDesc(
			"pz_server_info", "Constant 1, carrying the installed Steam build id.",
			[]string{"build_id"}, nil),
		backupLastRun: prometheus.NewDesc(
			"pz_backup_last_run_timestamp_seconds",
			"When a backup was last attempted.", nil, nil),
		backupLastOK: prometheus.NewDesc(
			"pz_backup_last_success_timestamp_seconds",
			"When a backup last succeeded.", nil, nil),
		backupBytes: prometheus.NewDesc(
			"pz_backup_last_size_bytes", "Size of the most recent archive.", nil, nil),
		backupCount: prometheus.NewDesc(
			"pz_backup_count", "Backup generations currently kept.", nil, nil),
	}
}

func (c *Collector) Describe(ch chan<- *prometheus.Desc) {
	c.up.Describe(ch)
	c.errors.Describe(ch)
	ch <- c.playersOnline
	ch <- c.playerInfo
	ch <- c.serverInfo
	ch <- c.backupLastRun
	ch <- c.backupLastOK
	ch <- c.backupBytes
	ch <- c.backupCount
}

// Collect queries all three sources. Each failure is contained: one broken
// source must not blank the other two, and the scrape itself never fails, because
// an exporter that stops answering is indistinguishable from one that has been
// removed.
func (c *Collector) Collect(ch chan<- prometheus.Metric) {
	c.collectPlayers(ch)
	c.collectBackups(ch)
	c.collectVersion(ch)
	c.up.Collect(ch)
	c.errors.Collect(ch)
}

func (c *Collector) collectPlayers(ch chan<- prometheus.Metric) {
	snap, err := c.playerSource.Query()
	if err != nil {
		c.up.Set(0)
		c.errors.WithLabelValues("rcon").Inc()
		return
	}
	c.up.Set(1)
	ch <- prometheus.MustNewConstMetric(
		c.playersOnline, prometheus.GaugeValue, float64(snap.Count))
	if !c.opts.ExportPlayerNames {
		return
	}
	for _, name := range snap.Names {
		ch <- prometheus.MustNewConstMetric(
			c.playerInfo, prometheus.GaugeValue, 1, name)
	}
}

func (c *Collector) collectBackups(ch chan<- prometheus.Metric) {
	status, err := c.backupSource.Status()
	if err != nil {
		c.errors.WithLabelValues("backups").Inc()
		return
	}
	ch <- prometheus.MustNewConstMetric(
		c.backupLastRun, prometheus.GaugeValue, float64(status.Timestamp.Unix()))
	if status.State == "ok" {
		ch <- prometheus.MustNewConstMetric(
			c.backupLastOK, prometheus.GaugeValue, float64(status.Timestamp.Unix()))
		ch <- prometheus.MustNewConstMetric(
			c.backupBytes, prometheus.GaugeValue, float64(status.Bytes))
	}
	count, err := c.backupSource.Count()
	if err != nil {
		c.errors.WithLabelValues("backups").Inc()
		return
	}
	ch <- prometheus.MustNewConstMetric(
		c.backupCount, prometheus.GaugeValue, float64(count))
}

func (c *Collector) collectVersion(ch chan<- prometheus.Metric) {
	id, err := c.versionSource.BuildID()
	if err != nil {
		c.errors.WithLabelValues("manifest").Inc()
		return
	}
	ch <- prometheus.MustNewConstMetric(c.serverInfo, prometheus.GaugeValue, 1, id)
}
```

- [x] **Step 4: Run the tests again**

Run: `cd exporter && go test ./... ; cd ..`
Expected: PASS

- [x] **Step 5: Commit**

```bash
git add exporter/internal/collector/
git commit -m "feat: add the prometheus collector"
```

---

### Task 7: The binary, its image and the Compose service

**Files:**
- Create: `exporter/main.go`, `Dockerfile.exporter`
- Modify: `docker-compose.yml`

**Interfaces:**
- Consumes: everything from Tasks 3 to 6
- Produces: a container serving `/metrics` on `:9401`, and a `pz-exporter` Compose service.

- [x] **Step 1: Write main.go**

```go
// Command exporter serves Project Zomboid server and backup metrics for
// Prometheus.
package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/SWATPeaceKeeper/zomboid-server-docker/exporter/internal/backups"
	"github.com/SWATPeaceKeeper/zomboid-server-docker/exporter/internal/collector"
	"github.com/SWATPeaceKeeper/zomboid-server-docker/exporter/internal/manifest"
	"github.com/SWATPeaceKeeper/zomboid-server-docker/exporter/internal/players"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

func env(key, fallback string) string {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		return v
	}
	return fallback
}

// backupAdapter satisfies collector.BackupSource over a directory.
type backupAdapter struct{ dir string }

func (b backupAdapter) Status() (backups.Status, error) { return backups.ReadStatus(b.dir) }
func (b backupAdapter) Count() (int, error)             { return backups.CountArchives(b.dir) }

// versionAdapter satisfies collector.VersionSource over an install directory.
type versionAdapter struct{ dir string }

func (v versionAdapter) BuildID() (string, error) { return manifest.BuildID(v.dir) }

func main() {
	password := os.Getenv("RCON_PASSWORD")
	if password == "" {
		// Refusing to start beats exporting pz_up 0 forever and looking like the
		// server is down.
		log.Fatal("RCON_PASSWORD is not set; the exporter cannot query the server")
	}

	addr := fmt.Sprintf("%s:%s", env("RCON_HOST", "pz-server"), env("RCON_PORT", "27015"))
	timeout, err := time.ParseDuration(env("RCON_TIMEOUT", "5s"))
	if err != nil {
		log.Fatalf("RCON_TIMEOUT is not a duration: %v", err)
	}

	exportNames := true
	if raw, ok := os.LookupEnv("PZ_EXPORT_PLAYER_NAMES"); ok {
		if parsed, err := strconv.ParseBool(raw); err == nil {
			exportNames = parsed
		}
	}

	c := collector.New(
		players.NewClient(addr, password, timeout),
		backupAdapter{dir: env("BACKUP_DIR", "/data/backups")},
		versionAdapter{dir: env("PZ_SERVER_DIR", "/data/server")},
		collector.Options{ExportPlayerNames: exportNames},
	)

	registry := prometheus.NewRegistry()
	registry.MustRegister(c)

	listen := env("LISTEN_ADDR", ":9401")
	http.Handle("/metrics", promhttp.HandlerFor(registry, promhttp.HandlerOpts{}))
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write([]byte(`<html><body><a href="/metrics">metrics</a></body></html>`))
	})

	log.Printf("serving metrics on %s for %s", listen, addr)
	server := &http.Server{
		Addr:              listen,
		ReadHeaderTimeout: 10 * time.Second,
	}
	log.Fatal(server.ListenAndServe())
}
```

Note for the implementer: the root handler checks the path explicitly because
Go's default mux routes everything unmatched to `/`, and a metrics endpoint that
answers 200 for `/anything` makes broken scrape configurations look healthy.

- [x] **Step 2: Write the Dockerfile**

`Dockerfile.exporter`:

```dockerfile
# syntax=docker/dockerfile:1

FROM golang:1.27-trixie@sha256:9baa6b4187bbb98d240372a8a235ac0bb6b5ddd52bba1431dc2f7c0705862728 AS build

WORKDIR /src
COPY exporter/go.mod exporter/go.sum ./
RUN go mod download
COPY exporter/ ./
ENV CGO_ENABLED=0
RUN go build -trimpath -ldflags="-s -w" -o /out/pz-exporter .

FROM alpine:3@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b

LABEL org.opencontainers.image.title="Project Zomboid metrics exporter" \
  org.opencontainers.image.description="Prometheus metrics for a Project Zomboid server and its backups" \
  org.opencontainers.image.licenses="GPL-3.0-or-later" \
  org.opencontainers.image.source="https://github.com/SWATPeaceKeeper/zomboid-server-docker"

RUN addgroup -g 1000 pz && adduser -u 1000 -G pz -D -h /home/pz pz

COPY --from=build /out/pz-exporter /usr/local/bin/pz-exporter

USER 1000:1000
EXPOSE 9401

ENTRYPOINT ["/usr/local/bin/pz-exporter"]
```

- [x] **Step 3: Build it and measure the size**

```bash
docker build -f Dockerfile.exporter -t pz-exporter:dev .
docker images pz-exporter:dev --format '{{.Size}}'
```

Record the measured size in the commit message. Do not predict it beforehand.

- [x] **Step 4: Prove it serves metrics without a server to talk to**

```bash
docker run --rm -d --name pz-exporter-check -p 9401:9401 \
  -e RCON_PASSWORD=irrelevant -e RCON_HOST=127.0.0.1 pz-exporter:dev
sleep 2
curl -s localhost:9401/metrics | grep -E '^pz_(up|scrape_errors_total)'
docker rm -f pz-exporter-check
```

Expected: `pz_up 0` and `pz_scrape_errors_total{source="rcon"} 1`. This is the
important behaviour: with nothing to talk to, the exporter still answers.

- [x] **Step 5: Add the Compose service**

Insert into `docker-compose.yml` after `pz-backup`:

```yaml
  pz-exporter:
    build:
      context: .
      dockerfile: Dockerfile.exporter
    image: ghcr.io/swatpeacekeeper/zomboid-server-docker-exporter:latest
    container_name: pz-exporter
    restart: unless-stopped
    depends_on:
      - pz-server
    environment:
      RCON_HOST: "pz-server"
      RCON_PORT: "${RCON_PORT:-27015}"
      RCON_PASSWORD: "${PZ_RCON_PASSWORD:?set PZ_RCON_PASSWORD in your .env}"
      PZ_EXPORT_PLAYER_NAMES: "${PZ_EXPORT_PLAYER_NAMES:-true}"
      TZ: "${TZ:-Europe/Berlin}"
    volumes:
      - pz-server:/data/server:ro
      - pz-backups:/data/backups:ro
    networks:
      - pz-internal
    security_opt:
      - no-new-privileges:true
```

The port is deliberately not published: Prometheus reaches it over the network,
and anything else does not need to.

- [x] **Step 6: Validate and commit**

```bash
PZ_ADMIN_PASSWORD=x PZ_RCON_PASSWORD=y docker compose config --quiet
yamllint -c .yamllint docker-compose.yml
hadolint Dockerfile.exporter
git add exporter/main.go Dockerfile.exporter docker-compose.yml
git commit -m "feat: serve the metrics from a container"
```

---

### Task 8: The stack test covers the exporter

**Files:**
- Modify: `tests/stack-smoke.sh`

**Interfaces:**
- Consumes: the `pz-exporter` service from Task 7
- Produces: CI coverage of the exporter against a live server.

- [x] **Step 1: Add the assertion**

In `tests/stack-smoke.sh`, after the archive check and before the stop:

```bash
echo "==> Checking the exporter answers against the live server"
metrics="$(docker compose exec -T pz-exporter \
  wget -qO- http://127.0.0.1:9401/metrics)"

if ! printf '%s' "${metrics}" | grep -qE '^pz_up 1$'; then
  echo "!! pz_up is not 1; the exporter cannot reach the server over RCON" >&2
  printf '%s\n' "${metrics}" | grep -E '^pz_' >&2
  exit 1
fi

if ! printf '%s' "${metrics}" | grep -qE '^pz_players_online 0$'; then
  echo "!! pz_players_online missing or not zero on an empty server" >&2
  printf '%s\n' "${metrics}" | grep -E '^pz_' >&2
  exit 1
fi

if ! printf '%s' "${metrics}" | grep -q '^pz_backup_last_success_timestamp_seconds '; then
  echo "!! the exporter did not see the backup taken moments ago" >&2
  exit 1
fi
echo "==> Exporter reports pz_up 1 and sees the backup"
```

The third assertion is the valuable one: it proves the sidecar and the exporter
agree about a backup that actually happened in this run.

- [x] **Step 2: Verify locally as far as is safe**

```bash
shellcheck tests/stack-smoke.sh
shfmt -i 2 -d tests/stack-smoke.sh
```

Do **not** run the stack on the development laptop. CI is the proof.

- [x] **Step 3: Commit and watch CI**

```bash
git add tests/stack-smoke.sh
git commit -m "test: assert the exporter answers against a live server"
git push
gh run watch
```

Expected: the `smoke` job prints `==> Exporter reports pz_up 1 and sees the backup`.

---

### Task 9: Optional JVM metrics

**Files:**
- Modify: `Dockerfile`, `scripts/lib/jvm.sh`, `scripts/entrypoint.sh`
- Test: `tests/unit/jvm.bats`

**Interfaces:**
- Consumes: `jvm_set_heap` from `scripts/lib/jvm.sh`
- Produces: `jvm_set_jmx_agent <json_file> <jar_path> <port>` — appends the Java agent argument to `vmArgs`, idempotently. Called only when `PZ_JMX_METRICS=true`.

- [x] **Step 1: Measure the cost before committing to it**

```bash
docker images pz-server:dev --format '{{.Size}}'   # before
```

The agent jar is 10.7 MB. Add it, rebuild, measure again, and record both numbers
in the commit message. If the increase is unacceptable, stop and switch to
downloading the jar into `/data/server` on first enable instead — the design doc
notes this fallback.

- [x] **Step 2: Write the failing tests**

Append to `tests/unit/jvm.bats`:

```bash
@test "jvm_set_jmx_agent adds the agent argument" {
  jvm_set_jmx_agent "${JSON}" "/opt/pz/jmx.jar" "9404"
  run jq -r '.vmArgs | map(select(startswith("-javaagent"))) | length' "${JSON}"
  [ "$output" = "1" ]
  run jq -r '.vmArgs | map(select(startswith("-javaagent"))) | join("")' "${JSON}"
  [[ "$output" == *"/opt/pz/jmx.jar=9404"* ]]
}

@test "jvm_set_jmx_agent is idempotent" {
  jvm_set_jmx_agent "${JSON}" "/opt/pz/jmx.jar" "9404"
  jvm_set_jmx_agent "${JSON}" "/opt/pz/jmx.jar" "9404"
  run jq -r '.vmArgs | map(select(startswith("-javaagent"))) | length' "${JSON}"
  [ "$output" = "1" ]
}

@test "jvm_set_jmx_agent keeps the heap flags" {
  jvm_set_heap "${JSON}" "4g"
  jvm_set_jmx_agent "${JSON}" "/opt/pz/jmx.jar" "9404"
  run jq -r '.vmArgs | map(select(startswith("-Xmx"))) | join("")' "${JSON}"
  [ "$output" = "-Xmx4g" ]
}

@test "jvm_set_heap does not remove an existing agent" {
  jvm_set_jmx_agent "${JSON}" "/opt/pz/jmx.jar" "9404"
  jvm_set_heap "${JSON}" "4g"
  run jq -r '.vmArgs | map(select(startswith("-javaagent"))) | length' "${JSON}"
  [ "$output" = "1" ]
}
```

- [x] **Step 3: Run them and watch them fail**

Run: `./tests/run-unit.sh`
Expected: FAIL — `jvm_set_jmx_agent: command not found`.

- [x] **Step 4: Implement**

Append to `scripts/lib/jvm.sh`:

```bash
# Attaches the Prometheus JMX agent to the server JVM.
#
# This is opt-in and off by default: it runs third-party code inside the game's
# JVM and opens a listener. Nobody should pay for that who did not ask.
jvm_set_jmx_agent() {
  local file="$1" jar="$2" port="$3" tmp

  if [ ! -f "${file}" ]; then
    log_error "JVM configuration ${file} not found."
    return 1
  fi
  if [ ! -f "${jar}" ]; then
    log_error "JMX agent ${jar} not found in this image."
    return 1
  fi

  tmp="$(mktemp "${file}.XXXXXX")"
  jq --arg agent "-javaagent:${jar}=${port}:/opt/pz/jmx-config.yaml" '
    .vmArgs = (
      ((.vmArgs // []) | map(select(startswith("-javaagent") | not)))
      + [$agent]
    )
  ' "${file}" >"${tmp}"

  cat "${tmp}" >"${file}"
  rm -f "${tmp}"
  log_info "JMX agent enabled on port ${port}"
}
```

In `scripts/entrypoint.sh`, in `configure_phase`, after the `jvm_set_heap` call:

```bash
  if [ "${PZ_JMX_METRICS:-false}" = "true" ]; then
    jvm_set_jmx_agent "${PZ_SERVER_DIR}/ProjectZomboid64.json" \
      "/opt/pz/jmx_prometheus_javaagent.jar" "${PZ_JMX_PORT:-9404}"
  fi
```

- [x] **Step 5: Add the agent and its config to the server image**

In `Dockerfile`, add a stage before the runtime stage:

```dockerfile
FROM steamcmd/steamcmd:ubuntu-24@sha256:2fbec2969d6caf1d203b62a365c0198c17c7eb9859b39f715c8acabfe917c182 AS jmx

ARG JMX_VERSION=1.6.0
ARG JMX_SHA256=a95983fd96e865d2bcdf911cc500e7c82808c27ab9fd226bf96732b6c3d8c46e

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# hadolint ignore=DL3008
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl \
  && rm -rf /var/lib/apt/lists/* \
  && curl -fsSL -o /tmp/jmx.jar \
  "https://github.com/prometheus/jmx_exporter/releases/download/${JMX_VERSION}/jmx_prometheus_javaagent-${JMX_VERSION}.jar" \
  && echo "${JMX_SHA256}  /tmp/jmx.jar" | sha256sum -c -
```

In the runtime stage, after the scripts are copied:

```dockerfile
COPY --from=jmx --chown=root:root /tmp/jmx.jar /opt/pz/jmx_prometheus_javaagent.jar
COPY --chown=pz:pz jmx-config.yaml /opt/pz/jmx-config.yaml

EXPOSE 9404
```

Create `jmx-config.yaml` at the repository root:

```yaml
---
# The defaults export the standard jvm_* metrics: heap by area, garbage
# collection, threads and class loading. No MBean rules are added, because
# Project Zomboid registers nothing useful of its own.
lowercaseOutputName: true
lowercaseOutputLabelNames: true
```

- [x] **Step 6: Verify the image builds and the agent is present**

```bash
docker build -t pz-server:dev .
docker run --rm --entrypoint /bin/bash pz-server:dev \
  -c 'ls -l /opt/pz/jmx_prometheus_javaagent.jar /opt/pz/jmx-config.yaml'
docker images pz-server:dev --format '{{.Size}}'   # after
./tests/run-unit.sh
```

- [x] **Step 7: Lint and commit**

```bash
shellcheck scripts/lib/jvm.sh scripts/entrypoint.sh
shfmt -i 2 -d scripts/
hadolint Dockerfile
yamllint -c .yamllint jmx-config.yaml
git add Dockerfile jmx-config.yaml scripts/lib/jvm.sh scripts/entrypoint.sh tests/unit/jvm.bats
git commit -m "feat: optional jvm metrics via the prometheus jmx agent

Image size before: <measured>. After: <measured>."
```

---

### Task 10: Monitoring overlay and dashboard

**Files:**
- Create: `docker-compose.monitoring.yml`, `grafana/pz-dashboard.json`

**Interfaces:**
- Consumes: the exporter from Task 7 and the optional JMX port from Task 9
- Produces: an opt-in overlay and an importable dashboard.

- [x] **Step 1: Write the overlay**

`docker-compose.monitoring.yml`:

```yaml
---
# Overlay for an existing Prometheus that scrapes over a shared Docker network.
#
#   docker compose -f docker-compose.yml -f docker-compose.monitoring.yml up -d
#
# The network is external and must already exist; this file does not create it,
# because the monitoring stack owns it.
services:
  pz-exporter:
    networks:
      - pz-internal
      - monitoring

  pz-server:
    networks:
      - pz-internal
      - monitoring

networks:
  monitoring:
    external: true
```

Scrape configuration for Prometheus, to be documented rather than shipped:

```yaml
scrape_configs:
  - job_name: project-zomboid
    static_configs:
      - targets: ["pz-exporter:9401"]
  # Only when PZ_JMX_METRICS=true
  - job_name: project-zomboid-jvm
    static_configs:
      - targets: ["pz-server:9404"]
```

- [x] **Step 2: Build the dashboard**

Create `grafana/pz-dashboard.json` with these panels, all using a
`${DS_PROMETHEUS}` datasource variable so it imports anywhere:

1. **Stat** — "Server up", `pz_up`, red at 0 and green at 1.
2. **Time series** — "Players online", `pz_players_online`.
3. **Stat** — "Backup age", `time() - pz_backup_last_success_timestamp_seconds`,
   unit seconds, thresholds green under 8 h, amber under 24 h, red beyond.
4. **Stat** — "Backup generations", `pz_backup_count`.
5. **Time series** — "Backup size", `pz_backup_last_size_bytes`, unit bytes.
6. **Time series** — "JVM heap used", `jvm_memory_bytes_used{area="heap"}`, with
   the panel description noting it stays empty unless `PZ_JMX_METRICS=true`.
7. **Stat** — "Build id", `pz_server_info`, showing the `build_id` label.

Build it in a real Grafana, then export via **Share → Export → Export for sharing
externally** so the datasource is templated, and save the result. Hand-writing
dashboard JSON produces files that do not import cleanly.

No CPU or memory panels: cAdvisor already provides those, and a second source for
the same number is a source of disagreement.

- [x] **Step 3: Verify the dashboard imports**

Import `grafana/pz-dashboard.json` into a Grafana instance pointed at a
Prometheus that scrapes the exporter. Every panel must render — with no data is
acceptable, with an error is not.

- [x] **Step 4: Commit**

```bash
yamllint -c .yamllint docker-compose.monitoring.yml
jq -e . grafana/pz-dashboard.json >/dev/null
git add docker-compose.monitoring.yml grafana/
git commit -m "feat: add monitoring overlay and grafana dashboard"
```

---

### Task 11: Documentation and release

**Files:**
- Modify: `README.md`, `docs/configuration.md`, `CHANGELOG.md`, `.github/workflows/release.yml`

- [x] **Step 1: Publish the exporter image**

In `.github/workflows/release.yml`, add to the `publish` matrix:

```yaml
          - image: zomboid-server-docker-exporter
            dockerfile: Dockerfile.exporter
```

- [x] **Step 2: Document the variables**

Add a "Metrics exporter" table to `docs/configuration.md` covering `RCON_HOST`,
`RCON_PORT`, `RCON_PASSWORD`, `RCON_TIMEOUT`, `LISTEN_ADDR`, `PZ_SERVER_DIR`,
`BACKUP_DIR` and `PZ_EXPORT_PLAYER_NAMES`, and add `PZ_JMX_METRICS` and
`PZ_JMX_PORT` to the server container table.

- [x] **Step 3: Add a Metrics section to the README**

Place it after "Backups". Cover: what is exported and what deliberately is not
(cAdvisor already has container CPU and memory), the metric table from spec §4,
how to scrape it, how to turn on JVM metrics and what that costs, and how to
import the dashboard. Include the one-line warning that `pz_player_info` grows
series on a busy public server and how to turn it off.

- [x] **Step 4: Update the changelog**

Add an `## [Unreleased]` entry under `### Added` describing the exporter, the
backup status file, the optional JVM metrics and the dashboard. Note under
`### Changed` that the backup sidecar now writes `${BACKUP_DIR}/.status`.

- [x] **Step 5: Verify every documented command**

Run each command block in the new README section against the running stack in
CI or on a host with enough memory. A command that does not work as written is a
documentation bug and is fixed before committing.

- [x] **Step 6: Commit, then cut the release**

```bash
git add README.md docs/configuration.md CHANGELOG.md .github/workflows/release.yml
git commit -m "docs: document the metrics exporter"
git push
gh run watch
```

Once CI is green on that commit, cut `v1.2.0` — a minor release, since this adds
features and changes nothing existing setups depend on:

```bash
git tag -a v1.2.0 -m "v1.2.0 - metrics"
git push origin v1.2.0
```

---

## Self-review notes

Checked against the spec:

- §3 architecture, three read-only inputs → Tasks 6, 7
- §4 exporter, file structure, metric table, configuration, error handling → Tasks 3–7
- §5 backup status file, three states → Task 2, consumed in Task 4
- §6 JVM metrics, opt-in, default off → Task 9
- §7 integration, overlay and dashboard → Task 10
- §8 testing, parsers against captured output, collector with failing sources, stack test → Tasks 3–6, 8
- §9 both unverified assumptions → Task 1, which gates Task 5
- §10 out of scope → nothing in the plan implements it
- §11 risks → mitigations appear in Tasks 3 (fixture-driven parser), 6 (`ExportPlayerNames`), 9 (opt-in), 3 (per-scrape timeout)

Type consistency: `players.Snapshot{Count, Names}`, `backups.Status{Timestamp,
State, Archive, Bytes}` and `manifest.BuildID(serverDir)` are defined in Tasks 3,
4 and 5 and used with those exact names in Tasks 6 and 7. The collector's three
interfaces are named `PlayerSource`, `BackupSource` and `VersionSource`
throughout. `Status.State` is deliberately not called `Status.Status`.
