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

// ParseStatus reads the key=value file the sidecar writes.
//
// Unknown keys are ignored on purpose, so a newer sidecar can add fields without
// breaking an exporter that has not been updated alongside it.
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
		return Status{}, fmt.Errorf("no status key found in %d parsed fields", len(fields))
	}

	seconds, err := strconv.ParseInt(fields["timestamp"], 10, 64)
	if err != nil {
		return Status{}, fmt.Errorf("parsing timestamp %q: %w", fields["timestamp"], err)
	}

	// An absent or unparsable size is zero rather than an error: the size is
	// decoration, the outcome is not.
	size, _ := strconv.ParseInt(fields["bytes"], 10, 64)

	return Status{
		Timestamp: time.Unix(seconds, 0).UTC(),
		State:     state,
		Archive:   fields["archive"],
		Bytes:     size,
	}, nil
}

// ReadStatus reads the status file the sidecar leaves in the backup directory.
func ReadStatus(dir string) (Status, error) {
	path := filepath.Join(dir, ".status")
	raw, err := os.ReadFile(path) // #nosec G304 - the path comes from configuration
	if err != nil {
		return Status{}, fmt.Errorf("reading %s: %w", path, err)
	}
	return ParseStatus(string(raw))
}

// CountArchives counts backups. They are tar archives or directories depending
// on BACKUP_MODE, so both shapes count.
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
