#!/usr/bin/env bash
# Shared helpers for the bats suite.

REPO_ROOT="${REPO_ROOT:-/code}"
export REPO_ROOT

# Creates a per-test temporary directory in TEST_TMP and removes it afterwards.
setup_tmpdir() {
  TEST_TMP="$(mktemp -d)"
  export TEST_TMP
}

teardown_tmpdir() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "${TEST_TMP}" ]; then
    rm -rf "${TEST_TMP}"
  fi
}
