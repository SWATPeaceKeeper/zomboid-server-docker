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

func healthy() *Collector {
	return New(
		stubPlayers{snap: players.Snapshot{Count: 2, Names: []string{"Bob", "Alice"}}},
		stubBackups{
			status: backups.Status{State: "ok", Timestamp: time.Unix(100, 0), Bytes: 42},
			count:  3,
		},
		stubVersion{id: "24909836"},
		Options{ExportPlayerNames: true},
	)
}

func TestHealthyServerReportsPlayers(t *testing.T) {
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
		t.Error("a backup metric was collected despite the source failing")
	}
	if got := testutil.CollectAndCount(c, "pz_server_info"); got != 1 {
		t.Errorf("pz_server_info was collected %d times, want 1", got)
	}
}

func TestFailedBackupDoesNotMoveTheSuccessTimestamp(t *testing.T) {
	// The gap between the success timestamp and now is how stale the newest
	// usable backup is. A failed run must not reset that clock.
	c := New(
		stubPlayers{snap: players.Snapshot{}},
		stubBackups{
			status: backups.Status{State: "failed", Timestamp: time.Unix(500, 0)},
			count:  2,
		},
		stubVersion{id: "1"},
		Options{},
	)
	if got := testutil.CollectAndCount(c, "pz_backup_last_run_timestamp_seconds"); got != 1 {
		t.Errorf("last_run was collected %d times, want 1", got)
	}
	if got := testutil.CollectAndCount(c, "pz_backup_last_success_timestamp_seconds"); got != 0 {
		t.Error("last_success was collected for a failed backup")
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
	// A pedantic registry rejects inconsistent descriptors and duplicate metrics,
	// which is exactly the class of mistake that only shows up in production.
	reg := prometheus.NewPedanticRegistry()
	if err := reg.Register(healthy()); err != nil {
		t.Fatalf("registering the collector: %v", err)
	}
	families, err := reg.Gather()
	if err != nil {
		t.Fatalf("gathering: %v", err)
	}
	if len(families) == 0 {
		t.Error("no metric families were produced")
	}
}
