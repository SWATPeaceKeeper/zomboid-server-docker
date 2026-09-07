#!/usr/bin/env bash
# Shared helpers for the bats suite.

# `run !` and the other run flags are only guaranteed from bats 1.5.0. Without
# this declaration bats warns once per use, and a suite that prints warnings is
# one where the next real warning goes unread.
bats_require_minimum_version 1.5.0

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
