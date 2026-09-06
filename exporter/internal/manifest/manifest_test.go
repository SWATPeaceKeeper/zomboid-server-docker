package manifest

import (
	"os"
	"path/filepath"
	"testing"
)

// installWith writes a manifest into a throwaway install directory and returns
// that directory.
func installWith(t *testing.T, contents []byte) string {
	t.Helper()
	dir := t.TempDir()
	steamapps := filepath.Join(dir, "steamapps")
	if err := os.MkdirAll(steamapps, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(steamapps, "appmanifest_380870.acf")
	if err := os.WriteFile(path, contents, 0o644); err != nil {
		t.Fatal(err)
	}
	return dir
}

func TestBuildIDFromCapturedManifest(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "testdata", "appmanifest_380870.acf"))
	if err != nil {
		t.Fatal(err)
	}

	got, err := BuildID(installWith(t, raw))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got == "" {
		t.Fatal("BuildID is empty; the captured manifest was supposed to contain one")
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
	dir := installWith(t, []byte("\"AppState\"\n{\n\t\"appid\"\t\t\"380870\"\n}\n"))
	if _, err := BuildID(dir); err == nil {
		t.Error("expected an error when buildid is absent, got nil")
	}
}

func TestBuildIDIgnoresTargetBuildID(t *testing.T) {
	// The manifest also carries TargetBuildID, which is a different thing: it is
	// what Steam intends to install, not what is installed. Matching it would
	// report the wrong version mid-update.
	dir := installWith(t, []byte("\t\"TargetBuildID\"\t\t\"999\"\n\t\"buildid\"\t\t\"24909836\"\n"))
	got, err := BuildID(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != "24909836" {
		t.Errorf("BuildID = %q, want 24909836", got)
	}
}
