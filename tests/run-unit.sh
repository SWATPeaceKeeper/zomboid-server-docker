#!/usr/bin/env bash
# Runs the unit test suite inside the official bats container, so no local
# installation is required and CI and workstation behave identically.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BATS_IMAGE="${BATS_IMAGE:-bats/bats:1.14.0}"

exec docker run --rm \
  --volume "${REPO_ROOT}:/code" \
  --workdir /code \
  "${BATS_IMAGE}" \
  --print-output-on-failure \
  tests/unit
