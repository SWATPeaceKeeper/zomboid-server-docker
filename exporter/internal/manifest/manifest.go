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
// value. Only one field is wanted, so a full parser would be more machinery than
// the job deserves.
//
// The match is case-sensitive and includes the quotes on purpose. The same file
// carries "TargetBuildID", which is what Steam intends to install rather than
// what is installed; matching that would report the wrong version during an
// update.
var buildIDPattern = regexp.MustCompile(`"buildid"\s+"(\d+)"`)

// BuildID returns the Steam build id of the installed server.
func BuildID(serverDir string) (string, error) {
	path := filepath.Join(serverDir, "steamapps", "appmanifest_380870.acf")
	raw, err := os.ReadFile(path) // #nosec G304 - the path comes from configuration
	if err != nil {
		return "", fmt.Errorf("reading %s: %w", path, err)
	}
	m := buildIDPattern.FindSubmatch(raw)
	if m == nil {
		return "", fmt.Errorf("no buildid field in %s", path)
	}
	return string(m[1]), nil
}
