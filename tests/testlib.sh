#!/usr/bin/env bash
# Shared regression-test helpers. Tests intentionally avoid `set -e` so one
# failure cannot hide the remaining release-safety signal.
set -uo pipefail

ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TEST_ROOT="${TEST_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/vps-guard-tests.XXXXXX")}" 
export ROOT TEST_ROOT VPSG_ROOT="$ROOT" NO_COLOR=1
PASS=0
FAIL=0

new_case_env() {
  local name base
  name="${1:-case}"
  base="$TEST_ROOT/$name"
  CASE_BASE="$base"; export CASE_BASE
  mkdir -p "$base" "$base/mockbin"
  export VPSG_STATE_DIR="$base/state"
  export VPSG_BACKUP_DIR="$base/state/backups"
  export VPSG_LOG_DIR="$base/log"
  export VPSG_ETC_DIR="$base/etc"
  export VPSG_SYSTEMD_DIR="$base/systemd"
  export VPSG_SSH_CONFIG_DIR="$base/sshd_config.d"
  export VPSG_SSH_MAIN_CONFIG="$base/sshd_config"
  export VPSG_UFW_DIR="$base/ufw"
  export VPSG_UFW_DEFAULT="$base/default-ufw"
  export VPSG_FAIL2BAN_JAIL_DIR="$base/fail2ban"
  export VPSG_APT_CONF_DIR="$base/apt-conf"
  export VPSG_APT_KEYRINGS_DIR="$base/keyrings"
  export VPSG_APT_SOURCES_DIR="$base/sources"
  export VPSG_SYSCTL_DIR="$base/sysctl"
  export VPSG_ASSUME_YES=1
  export PATH="$base/mockbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  printf '%s\n' "$base"
}

run_test() {
  local name="$1" fn="$2" rc
  if "$fn"; then
    printf 'PASS: %s\n' "$name"
    PASS=$((PASS+1))
  else
    rc=$?
    printf 'FAIL: %s (rc=%s)\n' "$name" "$rc"
    FAIL=$((FAIL+1))
  fi
}

assert_eq() { [[ "${1-}" == "${2-}" ]]; }
assert_ne() { [[ "${1-}" != "${2-}" ]]; }
assert_contains() { [[ "${1-}" == *"${2-}"* ]]; }
assert_not_contains() { [[ "${1-}" != *"${2-}"* ]]; }
assert_file() { [[ -f "$1" ]]; }
assert_dir() { [[ -d "$1" ]]; }
assert_rc() { local want="$1"; shift; "$@" >/dev/null 2>&1; [[ $? -eq "$want" ]]; }

source_core() {
  # shellcheck disable=SC1090
  . "$ROOT/core/common.sh"
}
source_inspect() { source_core; . "$ROOT/core/inspect.sh"; }
source_platform() { source_core; . "$ROOT/core/platform.sh"; }
source_module_defs() {
  local module="$1"
  # Avoid executing the module's action dispatcher while keeping the same
  # definitions actually shipped in the release.
  # shellcheck disable=SC1090
  . <(awk '/^action=/{exit} {print}' "$ROOT/modules/builtin/$module/module.sh")
}
source_transaction() {
  source_core
  . "$ROOT/core/platform.sh"
  . "$ROOT/core/router.sh"
  . "$ROOT/core/transaction.sh"
}

make_mock() {
  local base="$1" name="$2"
  shift 2
  cat > "$base/mockbin/$name"
  chmod 755 "$base/mockbin/$name"
}

finish_tests() {
  printf 'Tests: %d passed, %d failed\n' "$PASS" "$FAIL"
  ((FAIL==0))
}
