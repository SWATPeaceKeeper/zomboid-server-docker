// Package collector turns the three data sources into Prometheus metrics.
package collector

import (
	"github.com/SWATPeaceKeeper/zomboid-server-docker/exporter/internal/backups"
	"github.com/SWATPeaceKeeper/zomboid-server-docker/exporter/internal/players"
	"github.com/prometheus/client_golang/prometheus"
)

// PlayerSource is the live server.
type PlayerSource interface {
	Query() (players.Snapshot, error)
}

// BackupSource is the backup directory.
type BackupSource interface {
	Status() (backups.Status, error)
	Count() (int, error)
}

// VersionSource is the Steam installation.
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

// Collect queries all three sources.
//
// Each failure is contained: one broken source must not blank the other two. The
// scrape itself never fails, because an exporter that stops answering is
// indistinguishable from one that has been removed.
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
		// The player metrics are omitted rather than reported as zero. A server
		// that is down is not a server with nobody on it, and a dashboard must
		// not make an outage look like a quiet evening.
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
		ch <- prometheus.MustNewConstMetric(c.playerInfo, prometheus.GaugeValue, 1, name)
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

	// Only a successful run moves the success timestamp. That is the whole point
	// of the metric: the gap between it and now is how stale the newest usable
	// backup is.
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
