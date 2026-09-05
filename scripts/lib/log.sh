#!/usr/bin/env bash
# Uniform logging. Warnings and errors go to stderr so they survive log filters.

log_info() {
  printf '[pz] INFO: %s\n' "$*"
}

log_warn() {
  printf '[pz] WARN: %s\n' "$*" >&2
}

log_error() {
  printf '[pz] ERROR: %s\n' "$*" >&2
}
