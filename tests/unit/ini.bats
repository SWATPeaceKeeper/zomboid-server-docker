#!/usr/bin/env bats

load '../helpers/load'

setup() {
  setup_tmpdir
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/scripts/lib/log.sh"
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/scripts/lib/ini.sh"
  INI="${TEST_TMP}/servertest.ini"
  cat >"${INI}" <<'EOF'
# This is a comment that must survive
Public=false
PublicName=Old Name
Password=
UnknownFutureKey=keepme
EOF
}

teardown() {
  teardown_tmpdir
}

@test "ini_set replaces an existing key" {
  ini_set "${INI}" "Public" "true"
  run grep -c '^Public=true$' "${INI}"
  [ "$output" = "1" ]
}

@test "ini_set does not touch a key that only shares a prefix" {
  ini_set "${INI}" "Public" "true"
  run grep -c '^PublicName=Old Name$' "${INI}"
  [ "$output" = "1" ]
}

# The test above passes even with a naive prefix match, because `Public=` happens
# to come first in the fixture and stops the search. This one removes the exact
# key entirely, so a prefix match has nothing else to latch onto.
@test "ini_set appends rather than overwriting a prefix neighbour" {
  grep -v '^Public=' "${INI}" >"${INI}.stripped"
  mv "${INI}.stripped" "${INI}"

  ini_set "${INI}" "Public" "true"

  run grep -c '^PublicName=Old Name$' "${INI}"
  [ "$output" = "1" ]
  run grep -c '^Public=true$' "${INI}"
  [ "$output" = "1" ]
}

@test "ini_set preserves comments and unknown keys" {
  ini_set "${INI}" "Password" "secret"
  grep -q '^# This is a comment that must survive$' "${INI}"
  grep -q '^UnknownFutureKey=keepme$' "${INI}"
}

@test "ini_set appends a key that is missing" {
  ini_set "${INI}" "MaxPlayers" "8"
  run tail -n 1 "${INI}"
  [ "$output" = "MaxPlayers=8" ]
}

@test "ini_set handles values containing sed metacharacters" {
  ini_set "${INI}" "Password" 'a&b|c\d/e'
  run ini_get "${INI}" "Password"
  [ "$output" = 'a&b|c\d/e' ]
}

@test "ini_set ignores a commented-out occurrence of the key" {
  printf '# MaxPlayers=99\n' >>"${INI}"
  ini_set "${INI}" "MaxPlayers" "8"
  grep -q '^# MaxPlayers=99$' "${INI}"
  grep -q '^MaxPlayers=8$' "${INI}"
}

@test "ini_set writes an empty value" {
  ini_set "${INI}" "PublicName" ""
  run ini_get "${INI}" "PublicName"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "ini_get returns 1 for a missing key" {
  run ini_get "${INI}" "NoSuchKey"
  [ "$status" -eq 1 ]
}

@test "ini_ensure_file creates the file and its parent directory" {
  ini_ensure_file "${TEST_TMP}/nested/dir/new.ini"
  [ -f "${TEST_TMP}/nested/dir/new.ini" ]
}

@test "ini_ensure_file leaves an existing file untouched" {
  ini_ensure_file "${INI}"
  grep -q '^UnknownFutureKey=keepme$' "${INI}"
}

@test "ini_check_mod_ids warns for Build 42 ids without a backslash" {
  run ini_check_mod_ids 'FirstMod;\SecondMod' 'public'
  [ "$status" -eq 0 ]
  [[ "$output" == *"FirstMod"* ]]
  [[ "$output" != *"SecondMod has no leading backslash"* ]]
}

@test "ini_check_mod_ids stays silent on the legacy41 branch" {
  run ini_check_mod_ids 'FirstMod;SecondMod' 'legacy41'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "ini_check_mod_ids stays silent for an empty list" {
  run ini_check_mod_ids '' 'public'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}
