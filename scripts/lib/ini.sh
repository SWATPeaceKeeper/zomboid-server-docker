#!/usr/bin/env bash
# Reading and patching of the Project Zomboid server INI file.
#
# The approach of replacing a key in place while leaving everything else alone is
# taken from Danixu/project-zomboid-server-docker (scripts/entry.sh:178-188, GPL-3.0).
# It is reimplemented here in pure bash rather than with sed: the INI holds
# passwords and mod lists, which routinely contain the characters sed treats as
# metacharacters in a replacement.

ini_ensure_file() {
  local file="$1"
  mkdir -p "$(dirname "${file}")"
  if [ ! -f "${file}" ]; then
    : >"${file}"
  fi
}

# Prints the value of a key, or returns 1 when the key is not present.
ini_get() {
  local file="$1" key="$2" line
  [ -f "${file}" ] || return 1
  while IFS= read -r line || [ -n "${line}" ]; do
    if [ "${line%%=*}" = "${key}" ] && [ "${line}" != "${line#*=}" ]; then
      printf '%s\n' "${line#*=}"
      return 0
    fi
  done <"${file}"
  return 1
}

# Replaces the first `key=` line, or appends the pair when the key is absent.
ini_set() {
  local file="$1" key="$2" value="$3"
  local tmp line found=0

  ini_ensure_file "${file}"
  tmp="$(mktemp "${file}.XXXXXX")"

  while IFS= read -r line || [ -n "${line}" ]; do
    if [ "${found}" -eq 0 ] && [ "${line%%=*}" = "${key}" ] &&
      [ "${line}" != "${line#*=}" ]; then
      printf '%s=%s\n' "${key}" "${value}" >>"${tmp}"
      found=1
    else
      printf '%s\n' "${line}" >>"${tmp}"
    fi
  done <"${file}"

  if [ "${found}" -eq 0 ]; then
    printf '%s=%s\n' "${key}" "${value}" >>"${tmp}"
  fi

  # Copy the content instead of renaming, so the original inode, ownership and
  # mode survive. Bind-mounted files must not be replaced by a new file.
  cat "${tmp}" >"${file}"
  rm -f "${tmp}"
}

# Build 42 requires every entry in Mods= to carry a leading backslash; Build 41
# does not. Getting this wrong is the most common cause of "mods do not load".
# This warns and deliberately changes nothing: silently rewriting a user's
# configuration produces behaviour that cannot be reasoned about later.
ini_check_mod_ids() {
  local mod_ids="$1" branch="$2" entry
  if [ "${branch}" != "public" ] || [ -z "${mod_ids}" ]; then
    return 0
  fi
  local IFS=';'
  for entry in ${mod_ids}; do
    if [ -z "${entry}" ]; then
      continue
    fi
    case "${entry}" in
    \\*) ;;
    *)
      log_warn "mod id '${entry}' has no leading backslash. Build 42 expects" \
        "Mods=\\\\${entry}. The value is left unchanged."
      ;;
    esac
  done
  return 0
}
