# Test fixtures

These files are the source of truth for the parsers in `exporter/internal/`. If a
parser and a fixture disagree, the fixture is right.

Their provenance differs, and that difference matters when one of them starts
failing:

| File | Provenance |
|---|---|
| `players_empty.txt` | **Captured.** Printed by a Build 42 server with nobody connected, in CI run [34033815919](https://github.com/SWATPeaceKeeper/zomboid-server-docker/actions/runs/34033815919) on 2026-09-06. |
| `appmanifest_380870.acf` | **Captured.** The first 40 lines of the manifest SteamCMD wrote in that same run. It contains `"buildid" "24909836"`. |
| `players_populated.txt` | **Reconstructed, not captured.** CI has no way to make a player join, so the shape of the name lines could not be observed directly. It follows the format documented and parsed by [beyenilmez/pz-info-api](https://github.com/beyenilmez/pz-info-api/blob/main/internal/server/rconclient.go), an independent project that reads the same command against real servers. |

If `players_populated.txt` ever turns out to be wrong, replace it with a real
capture from a server with someone on it and fix the parser to match — in that
order.
