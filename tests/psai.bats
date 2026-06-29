#!/usr/bin/env bats
# Tests that need no Docker/cargo — safe for CI. Run: bats tests/
# (compose-config, vault round-trip and live install are covered by the host e2e.)

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "build assembles a syntactically valid installer" {
  run bash "$REPO/build.sh"
  [ "$status" -eq 0 ]
  run bash -n "$REPO/psai.sh"
  [ "$status" -eq 0 ]
}

@test "shellcheck is clean (warning level)" {
  if ! command -v shellcheck >/dev/null 2>&1; then skip "shellcheck not installed"; fi
  run shellcheck -S warning -e SC2034 "$REPO/psai.sh"
  [ "$status" -eq 0 ]
}

@test "i18n: every referenced t-key is defined" {
  # shellcheck disable=SC1090
  UI_LANG=en; source "$REPO/psai.sh"
  local missing=""
  for k in $(grep -rhoE '\$\(t [a-z0-9_]+\)' "$REPO/lib" | sed -E 's/\$\(t ([a-z0-9_]+)\)/\1/' | sort -u); do
    [ -z "$(UI_LANG=en t "$k")" ] && [ -z "$(UI_LANG=ru t "$k")" ] && missing="$missing $k"
  done
  [ -z "$missing" ] || { echo "undefined keys:$missing"; false; }
}

@test "i18n: RU and EN key sets match (each key defined twice)" {
  run bash -c "grep -oE '(^|;; )[a-z0-9_]+\)' '$REPO/lib/10-i18n.sh' | sed -E 's/^;; //; s/\)//' | sort | uniq -c | awk '\$1!=2{print}'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "helpers: safe_name / trim / normalize_zone" {
  # shellcheck disable=SC1090
  source "$REPO/psai.sh"
  [ "$(safe_name 'My Stack!')" = "my_stack" ]
  [ "$(trim '  x  ')" = "x" ]
  [ "$(normalize_zone 'https://Foo.Bar/')" = "Foo.Bar" ]
}

@test "egress: mode->port mapping" {
  # shellcheck disable=SC1090
  source "$REPO/psai.sh"
  [ "$(eg_mode_port tor)" = "8118" ]
  [ "$(eg_mode_port vless)" = "8118" ]
  [ "$(eg_mode_port wireguard)" = "8888" ]
}

@test "profile: strict enables the vault, default uses .env" {
  # shellcheck disable=SC1090
  source "$REPO/psai.sh"
  NODE_MODE=single DEPLOY_PROFILE=local SECURITY_PROFILE=strict resolve_security_profile
  [ "$SEC_SEAL" = "true" ]
  SECURITY_PROFILE=default resolve_security_profile
  [ "$SEC_SEAL" = "false" ]
}

@test "versions.json is valid and carries an installer hash field" {
  run grep -q '"installer_sha256"' "$REPO/versions.json"
  [ "$status" -eq 0 ]
}
