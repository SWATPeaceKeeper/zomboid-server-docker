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

# Attaches the Prometheus JMX agent to the server JVM.
#
# Opt-in and off by default: it runs third-party code inside the game's JVM and
# opens a listener. Nobody should pay for that who did not ask for it.
jvm_set_jmx_agent() {
  local file="$1" jar="$2" port="$3" tmp

  if [ ! -f "${file}" ]; then
    log_error "JVM configuration ${file} not found. The server installation" \
      "looks incomplete."
    return 1
  fi
  if [ ! -f "${jar}" ]; then
    log_error "JMX agent ${jar} is not present in this image."
    return 1
  fi

  tmp="$(mktemp "${file}.XXXXXX")"
  jq --arg agent "-javaagent:${jar}=${port}:/opt/pz/jmx-config.yaml" '
    .vmArgs = (
      ((.vmArgs // []) | map(select(startswith("-javaagent") | not)))
      + [$agent]
    )
  ' "${file}" >"${tmp}"

  cat "${tmp}" >"${file}"
  rm -f "${tmp}"
  log_info "JMX agent enabled on port ${port}"
}

# What Build 42 needs on top of the Java heap. It streams the map using memory
# outside the heap, so a container limited to exactly the heap size is killed
# while working normally. The number is the one the README's memory table is
# built on; there is no second place to change it.
JVM_OFFHEAP_HEADROOM_BYTES=$((3 * 1024 * 1024 * 1024))

# Bytes from a JVM size string: 4g, 512m, 2048k, or a plain byte count.
jvm_size_to_bytes() {
  local value="$1" number unit
  number="${value%[gGmMkK]}"
  unit="${value#"${number}"}"

  case "${number}" in
  '' | *[!0-9]*) return 1 ;;
  esac

  case "${unit}" in
  g | G) printf '%s\n' "$((number * 1024 * 1024 * 1024))" ;;
  m | M) printf '%s\n' "$((number * 1024 * 1024))" ;;
  k | K) printf '%s\n' "$((number * 1024))" ;;
  '') printf '%s\n' "${number}" ;;
  *) return 1 ;;
  esac
}

# The container's own memory limit in bytes, or nothing when it has none.
#
# cgroup v2 writes "max" for unlimited; v1 has no such word and writes a number
# larger than any real machine instead, which is why both are filtered out. A
# host that exposes neither file simply has no limit to check against.
jvm_container_memory_limit() {
  local raw=""

  if [ -r /sys/fs/cgroup/memory.max ]; then
    raw="$(cat /sys/fs/cgroup/memory.max)"
  elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
    raw="$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)"
  fi

  case "${raw}" in
  '' | *[!0-9]*) return 0 ;;
  esac
  if [ "${raw}" -gt $((1 << 60)) ]; then
    return 0
  fi

  printf '%s\n' "${raw}"
}

# GiB, rounded up, for error messages. Whole numbers only: this is used to tell
# somebody which value to put in their .env, not to account for bytes.
jvm_bytes_to_gib() {
  printf '%s\n' "$((($1 + 1073741823) / 1073741824))"
}

# Refuses to start when the container cannot hold the configured heap plus the
# off-heap headroom.
#
# Takes the limit as an argument rather than reading it, so the caller decides
# where it comes from and this stays testable without a cgroup.
#
# Failing here is the point. Without the check the JVM starts, grows, and is
# killed by the OOM killer somewhere in the middle of a session, which reads like
# a crash rather than like the configuration mistake it is.
jvm_check_memory_limit() {
  local max_ram="$1" limit="$2" heap required

  if [ -z "${limit}" ]; then
    return 0
  fi

  if ! heap="$(jvm_size_to_bytes "${max_ram}")"; then
    log_error "PZ_MAX_RAM=${max_ram} is not a size. Use a number with g, m or" \
      "k, for example 4g."
    return 1
  fi

  required=$((heap + JVM_OFFHEAP_HEADROOM_BYTES))
  if [ "${limit}" -lt "${required}" ]; then
    log_error "This container may use $(jvm_bytes_to_gib "${limit}") GiB, but" \
      "PZ_MAX_RAM=${max_ram} needs about $(jvm_bytes_to_gib "${required}") GiB:" \
      "Build 42 streams the map outside the Java heap and wants roughly 3 GiB" \
      "on top of it. Raise PZ_MEM_LIMIT to at least" \
      "$(jvm_bytes_to_gib "${required}")g, or lower PZ_MAX_RAM."
    return 1
  fi
}
