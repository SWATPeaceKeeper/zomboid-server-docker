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
// A real Build 42 server with nobody connected answers exactly
// "Players connected (0):"; with players it adds one "- name" line each. The
// game documents none of this and has changed neighbouring output between
// builds, so this stays forgiving: it takes the count from a header line that
// carries a number in brackets, and otherwise counts the names it found.
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

// Query opens a connection, asks for the player list and closes again.
//
// A short-lived connection per scrape is deliberate: a pooled one would have to
// survive server restarts and reconnect on its own, and `players` is cheap
// enough that the simpler thing is also the right thing.
func (c *Client) Query() (Snapshot, error) {
	conn, err := rcon.Dial(c.addr, c.password,
		rcon.SetDialTimeout(c.timeout),
		rcon.SetDeadline(c.timeout),
	)
	if err != nil {
		return Snapshot{}, fmt.Errorf("connecting to %s: %w", c.addr, err)
	}
	defer func() { _ = conn.Close() }()

	raw, err := conn.Execute("players")
	if err != nil {
		return Snapshot{}, fmt.Errorf("running the players command: %w", err)
	}
	return Parse(raw)
}
