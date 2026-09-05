#!/usr/bin/env bash
# JVM heap configuration for the Project Zomboid server launcher.
#
# The heap size is set here and nowhere else. It could also be passed on the
# command line, but having two sources for the same value is a well known way to
# end up wondering which one the server actually used.

jvm_set_heap() {
  local file="$1" size="$2" tmp

  if [ ! -f "${file}" ]; then
    log_error "JVM configuration ${file} not found. The server installation" \
      "looks incomplete."
    return 1
  fi

  tmp="$(mktemp "${file}.XXXXXX")"
  jq --arg xms "-Xms${size}" --arg xmx "-Xmx${size}" '
    .vmArgs = (
      ((.vmArgs // [])
        | map(select((startswith("-Xms") or startswith("-Xmx")) | not)))
      + [$xms, $xmx]
    )
  ' "${file}" >"${tmp}"

  cat "${tmp}" >"${file}"
  rm -f "${tmp}"
  log_info "JVM heap set to ${size}"
}
