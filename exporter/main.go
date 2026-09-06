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
		// Refusing to start beats exporting pz_up 0 forever, which would look
		// exactly like a server that is down.
		log.Fatal("RCON_PASSWORD is not set; the exporter cannot query the server")
	}

	addr := fmt.Sprintf("%s:%s", env("RCON_HOST", "pz-server"), env("RCON_PORT", "27015"))
	timeout, err := time.ParseDuration(env("RCON_TIMEOUT", "5s"))
	if err != nil {
		log.Fatalf("RCON_TIMEOUT is not a duration: %v", err)
	}

	exportNames := true
	if raw, ok := os.LookupEnv("PZ_EXPORT_PLAYER_NAMES"); ok {
		parsed, err := strconv.ParseBool(raw)
		if err != nil {
			log.Fatalf("PZ_EXPORT_PLAYER_NAMES is not a boolean: %v", err)
		}
		exportNames = parsed
	}

	c := collector.New(
		players.NewClient(addr, password, timeout),
		backupAdapter{dir: env("BACKUP_DIR", "/data/backups")},
		versionAdapter{dir: env("PZ_SERVER_DIR", "/data/server")},
		collector.Options{ExportPlayerNames: exportNames},
	)

	registry := prometheus.NewRegistry()
	registry.MustRegister(c)

	mux := http.NewServeMux()
	mux.Handle("/metrics", promhttp.HandlerFor(registry, promhttp.HandlerOpts{}))
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		// The default mux sends everything unmatched to "/", and an endpoint that
		// answers 200 for /anything makes a mistyped scrape path look healthy.
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write([]byte(`<html><body><a href="/metrics">metrics</a></body></html>`))
	})

	listen := env("LISTEN_ADDR", ":9401")
	log.Printf("serving metrics on %s, querying %s", listen, addr)

	server := &http.Server{
		Addr:              listen,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}
	log.Fatal(server.ListenAndServe())
}
