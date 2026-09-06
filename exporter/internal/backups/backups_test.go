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

func TestReadStatusFromDisk(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, ".status"), []byte(okStatus), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := ReadStatus(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.State != "ok" {
		t.Errorf("State = %q, want ok", got.State)
	}
}

func TestCountArchives(t *testing.T) {
	dir := t.TempDir()
	for _, n := range []string{"pz-1.tar.zst", "pz-2.tar.zst", ".status", "README"} {
		if err := os.WriteFile(filepath.Join(dir, n), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	// dir-mode backups are directories, and they count too.
	if err := os.Mkdir(filepath.Join(dir, "pz-3"), 0o755); err != nil {
		t.Fatal(err)
	}

	got, err := CountArchives(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != 3 {
		t.Errorf("CountArchives = %d, want 3", got)
	}
}

func TestCountArchivesMissingDirectory(t *testing.T) {
	if _, err := CountArchives(filepath.Join(t.TempDir(), "absent")); err == nil {
		t.Error("expected an error for a missing directory, got nil")
	}
}
