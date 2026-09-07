# Contributing

Bug reports, fixes and documentation corrections are all welcome. So is a issue
that just says "this section of the README is wrong" — that is a real
contribution.

Before a larger change, open an issue first. This project deliberately has no
speculative features, so a pull request adding a flag nobody asked for is likely
to be declined however good the code is, and that is a waste of your evening.

## What you need

Docker with the Compose v2 plugin. That is all — every linter and every test
runs in a container, so there is no toolchain to install and no version of
anything to match.

For the end-to-end tests you also need about 10 GB of free disk: they install a
real Project Zomboid server.

## Getting set up

```bash
git clone https://github.com/SWATPeaceKeeper/zomboid-server-docker.git
cd zomboid-server-docker

# Git hooks: runs the linters on the files you touch
prek install
prek auto-update --cooldown-days 7
```

To run the stack while working on it, create a gitignored `.env`:

```bash
cat > .env <<'EOF'
PZ_ADMIN_PASSWORD=pick-something-long-and-not-reused
PZ_RCON_PASSWORD=a-different-long-one
EOF

docker compose up -d --build
```

**`--build` is not optional.** The services carry both an `image:` and a
`build:` section, and Compose's default pull policy prefers the published image
over your local source. Without `--build` you are testing the last release and
quietly ignoring every edit you made.

## Tests

```bash
./tests/run-unit.sh          # bats, a few seconds
./tests/compose-network.sh   # outbound connectivity check, a few seconds
```

Run both for any change. They are cheap and they catch most of what goes wrong.

```bash
./tests/smoke.sh             # image end-to-end, 20-40 min, ~10 GB download
./tests/stack-smoke.sh       # Compose end-to-end, same cost
```

Run one of these if you touched the entrypoint, a Dockerfile or the Compose
file. Otherwise let CI do it — it runs both on every pull request, and nightly.

Go tests, through the same pinned toolchain the release build uses:

```bash
docker run --rm -v "${PWD}/exporter:/src" -w /src \
  golang:1.27-trixie@sha256:9baa6b4187bbb98d240372a8a235ac0bb6b5ddd52bba1431dc2f7c0705862728 \
  go test ./...
```

### Writing tests

Test behaviour, not implementation. The existing suite asserts that a patched
INI still has its comments and unrelated keys, not that a particular command
ran — so a rewrite of `ini_set` that keeps the promise keeps the tests green.

Verify a new test actually catches something: break the code, watch it go red,
then fix it.

## Linting

`prek run` covers the files you changed. The full set, identical to CI:

```bash
find scripts tests \( -name '*.sh' -o -name '*.bats' \) -print0 \
  | xargs -0 docker run --rm -v "${PWD}:/mnt" koalaman/shellcheck:v0.11.0
find scripts tests \( -name '*.sh' -o -name '*.bats' \) -print0 \
  | xargs -0 docker run --rm -v "${PWD}:/mnt" -w /mnt mvdan/shfmt:v3.14.0-alpine -i 2 -d
for f in Dockerfile Dockerfile.backup Dockerfile.exporter tests/Dockerfile; do
  docker run --rm -i hadolint/hadolint:v2.15.1 hadolint - <"$f"
done
yamllint -c .yamllint .
zizmor --persona=regular .github/workflows/
./tests/check-lint-versions.sh
```

Zero warnings. If one genuinely cannot be fixed, add an inline ignore with a
comment explaining why — the `hadolint ignore=DL3008` lines show the shape.

**Tool versions in `.pre-commit-config.yaml` and in the `env:` block of
`.github/workflows/lint.yml` are kept identical on purpose.** If you bump one,
bump the other in the same commit. A linter that reports differently locally
than in CI turns every finding into an argument about which run to believe.

`./tests/check-lint-versions.sh` enforces that, in CI and as a pre-commit hook.
It also fails on a pin in the workflow it has never been told about, so a tool
added to CI cannot slip past it — teach it about the new pin, or list the pin as
CI-only with the others that have no hook to compare against.

## Style

**Shell.** `set -euo pipefail`, two-space indent (`shfmt -i 2`). Files under
`lib/` are sourced and define functions only. Build command lines as arrays so
values containing spaces survive.

**Comments explain why.** This codebase is dense with rationale comments, and
nearly every one records a decision or a failure that actually happened. Match
that. If you change the decision, change the comment; if you delete the code,
delete the comment.

**Errors say what to do next.** Include the concrete command where there is one.
Distinguish "nothing to do yet" from "broken" — the backup path returns exit
code 2 for the former so that a fresh install does not open with an error about
nothing being wrong.

**Go.** `gofmt` and `go vet` clean. Interfaces are declared where they are
consumed.

**Documentation ships with the change.** README, `docs/`, `CHANGELOG.md` — in
the same pull request, not as a follow-up.

## Commits and pull requests

- [Conventional Commits](https://www.conventionalcommits.org/): `feat:`, `fix:`,
  `docs:`, `refactor:`, `test:`, `chore:`, `ci:`.
- Imperative mood, subject line ≤72 characters, one logical change per commit.
- Branch off `main`, open a pull request. Nothing is pushed to `main` directly.
- Describe what the code does now. Not the approaches you discarded on the way,
  not what you almost did. Plain language: a bug fix is a bug fix, not a
  "critical stability improvement".
- Never commit a `.env` or a real credential. The test scripts use obviously
  fake values (`network-check-not-a-real-password`) for exactly this reason.

## Some things are already decided

Not to shut down discussion, but so you do not spend an evening on a pull
request that was never going to land. Each of these is arguable — open an issue
and argue it, rather than sending the change:

- **RCON is never published to the host.** It is full remote administration of
  the server.
- **The game is not baked into the image.** It installs into a volume, which is
  what makes the branch switchable and means no Steam content is redistributed.
- **The exporter only reads**, and does not export container CPU, memory or
  uptime. cAdvisor already produces those, and a second source for the same
  number is a source of disagreement.
- **Every `FROM` is pinned by digest**, and third-party Go binaries are compiled
  from source rather than pulled as release tarballs.
- **No configuration is added speculatively.** Every environment variable that
  exists is one somebody needed.

[CLAUDE.md](CLAUDE.md) has the longer version, including the traps that catch
people working in this repository for the first time.

## Security

Do not open a public issue for a vulnerability. See [SECURITY.md](SECURITY.md).

## AI-assisted contributions

They are welcome, and there are rules — disclose it, own the diff, run the tests
yourself. See [AI-POLICY.md](AI-POLICY.md).

## Licence

By contributing you agree that your work is licensed under GPL-3.0-or-later,
like the rest of the project.
