#!/usr/bin/env bash
# Runs the unit test suite inside a container, so no local installation is
# required and CI and workstation behave identically.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_IMAGE="${TEST_IMAGE:-pz-bats:local}"

docker build --quiet --tag "${TEST_IMAGE}" "${REPO_ROOT}/tests" >/dev/null

exec docker run --rm \
  --volume "${REPO_ROOT}:/code" \
  --workdir /code \
  "${TEST_IMAGE}" \
  --print-output-on-failure \
  tests/unit
