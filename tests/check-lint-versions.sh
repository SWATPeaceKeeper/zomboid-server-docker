#!/usr/bin/env bash
# Fails when a linter version in .pre-commit-config.yaml and the matching pin in
# the env: block of .github/workflows/lint.yml disagree.
#
# Both files say the versions are kept identical on purpose, and nothing enforced
# it. Renovate only ever manages one of the two: it reads pre-commit `rev:` keys
# and `uses:` lines, not arbitrary workflow environment values. So the next hook
# update moves the local side and leaves CI behind — the automation causing the
# drift the comment exists to prevent.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
precommit="${repo_root}/.pre-commit-config.yaml"
workflow="${repo_root}/.github/workflows/lint.yml"

# The `rev:` of the pre-commit repo whose URL contains $1.
precommit_rev() {
  awk -v repo="$1" '
    $1 == "-" && $2 == "repo:" { current = (index($3, repo) > 0) }
    current && $1 == "rev:" { print $2; exit }
  ' "${precommit}"
}

# The image reference from a local hook's `entry:` line, which is how shfmt is
# pinned: `entry: mvdan/shfmt:v3.14.0-alpine -i 2 -w`.
precommit_entry_image() {
  awk -v image="$1" '$1 == "entry:" && index($2, image) == 1 { print $2; exit }' "${precommit}"
}

# The value of a key in the workflow's env: block.
workflow_env() {
  awk -v key="$1:" '$1 == key { print $2; exit }' "${workflow}"
}

# Comparable form of a pin: without the image name it may carry, and without the
# leading `v` that pre-commit revs use and a plain version string does not.
normalize() {
  local value="${1##*:}"
  printf '%s\n' "${value#v}"
}

# tool | key in the workflow env: block | how the same version is pinned locally
checks=(
  "shellcheck|SHELLCHECK_IMAGE|$(precommit_rev koalaman/shellcheck-precommit)"
  "shfmt|SHFMT_IMAGE|$(precommit_entry_image mvdan/shfmt)"
  "hadolint|HADOLINT_IMAGE|$(precommit_rev hadolint/hadolint)"
  "yamllint|YAMLLINT_VERSION|$(precommit_rev adrienverge/yamllint)"
)

# Pins with no pre-commit hook to compare against. Listed rather than skipped
# silently, so that a new pin in the workflow has to be classified as either
# compared or deliberately CI-only.
ci_only=(ZIZMOR_VERSION GO_IMAGE)

status=0

for check in "${checks[@]}"; do
  IFS='|' read -r tool key local_pin <<<"${check}"
  ci_pin="$(workflow_env "${key}")"

  if [ -z "${local_pin}" ] || [ -z "${ci_pin}" ]; then
    printf '%s: could not read the version from both files — has a key been renamed?\n' "${tool}" >&2
    status=1
    continue
  fi

  local_version="$(normalize "${local_pin}")"
  ci_version="$(normalize "${ci_pin}")"
  if [ "${local_version}" != "${ci_version}" ]; then
    printf '%s: .pre-commit-config.yaml pins %s, %s pins %s\n' \
      "${tool}" "${local_version}" "${key}" "${ci_version}" >&2
    status=1
  fi
done

# Every pin in the env: block has to be accounted for, so adding a tool to CI
# without teaching this check about it is itself a failure. This is the guardrail
# hadolint lacked when Dockerfile.exporter stayed out of its list for months.
known="${checks[*]} ${ci_only[*]}"
while read -r key; do
  case " ${known} " in
  *"|${key}|"* | *" ${key} "*) ;;
  *)
    printf '%s is pinned in %s but not covered by this check.\n' "${key}" "${workflow##*/}" >&2
    printf '  Add it to checks with its pre-commit counterpart, or to ci_only if it has none.\n' >&2
    status=1
    ;;
  esac
done < <(awk '
  /^env:/ { in_env = 1; next }
  in_env && /^[^[:space:]]/ { exit }
  in_env && $1 ~ /(_IMAGE|_VERSION):$/ { sub(/:$/, "", $1); print $1 }
' "${workflow}")

if [ "${status}" -ne 0 ]; then
  printf '\nBoth files have to move in the same commit, or prek and CI report different findings.\n' >&2
  exit 1
fi

echo "Linter versions agree between .pre-commit-config.yaml and .github/workflows/lint.yml"
