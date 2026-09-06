package players

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/gorcon/rcon"
	"github.com/gorcon/rcon/rcontest"
)

// The fixtures are what a real server printed. They are the source of truth for
// this format, not anything assumed here: Project Zomboid does not document it.
// See exporter/testdata/README.md for which of them were captured and which was
// reconstructed.
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
	if got.Count == 0 {
		t.Fatal("the fixture is supposed to have players in it")
	}
	if got.Count != len(got.Names) {
		t.Errorf("Count = %d but parsed %d names: %v", got.Count, len(got.Names), got.Names)
	}
}

func TestParseRejectsEmptyInput(t *testing.T) {
	if _, err := Parse("   \n\n"); err == nil {
		t.Error("expected an error for empty input, got nil")
	}
}

func TestParseHandlesCRLF(t *testing.T) {
	got, err := Parse("Players connected (1):\r\n- Bob\r\n")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got.Names) != 1 || got.Names[0] != "Bob" {
		t.Errorf("Names = %v, want [Bob]", got.Names)
	}
}

func TestParseFallsBackToCountingNames(t *testing.T) {
	// No header carrying a number; the names are all there is to go on.
	got, err := Parse("- Bob\n- Alice\n")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.Count != 2 {
		t.Errorf("Count = %d, want 2", got.Count)
	}
}

func TestParseKeepsNamesContainingSpaces(t *testing.T) {
	got, err := Parse("Players connected (1):\n- Big Bad Bob\n")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got.Names) != 1 || got.Names[0] != "Big Bad Bob" {
		t.Errorf("Names = %v, want [Big Bad Bob]", got.Names)
	}
}

func TestClientQueryAgainstFakeServer(t *testing.T) {
	server := rcontest.NewServer(
		rcontest.SetSettings(rcontest.Settings{Password: "secret"}),
		rcontest.SetCommandHandler(func(c *rcontest.Context) {
			if c.Request().Body() != "players" {
				t.Errorf("unexpected command %q", c.Request().Body())
			}
			_, _ = rcon.NewPacket(
				rcon.SERVERDATA_RESPONSE_VALUE,
				c.Request().ID,
				"Players connected (1):\n- Bob",
			).WriteTo(c.Conn())
		}),
	)
	defer server.Close()

	got, err := NewClient(server.Addr(), "secret", 2*time.Second).Query()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.Count != 1 || len(got.Names) != 1 || got.Names[0] != "Bob" {
		t.Errorf("got %+v, want one player named Bob", got)
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
