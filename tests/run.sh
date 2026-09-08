#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export VPSG_ROOT="$ROOT"
export NO_COLOR=1
export VPSG_STATE_DIR="${TMPDIR:-/tmp}/vps-guard-test-state-$$"
export VPSG_BACKUP_DIR="$VPSG_STATE_DIR/backups"
export VPSG_LOG_DIR="${TMPDIR:-/tmp}/vps-guard-test-log-$$"
export VPSG_ETC_DIR="${TMPDIR:-/tmp}/vps-guard-test-etc-$$"
trap 'rm -rf "$VPSG_STATE_DIR" "$VPSG_LOG_DIR" "$VPSG_ETC_DIR"' EXIT

pass=0
fail=0
run_test() {
  local name="$1"; shift
  if "$@"; then echo "PASS: $name"; pass=$((pass+1)); else echo "FAIL: $name"; fail=$((fail+1)); fi
}

help_test() { "$ROOT/bin/vpsg" --help | grep -q 'Safe Change'; }
version_test() { [[ "$("$ROOT/bin/vpsg" --version)" == "0.2.0" ]]; }
modules_test() {
  local out; out="$("$ROOT/bin/vpsg" module list)"
  for m in baseline bbr docker drift exposure fail2ban firewall ssh swap system; do grep -qx "$m" <<<"$out" || return 1; done
}
syntax_test() {
  local f
  while IFS= read -r -d '' f; do bash -n "$f" || return 1; done < <(find "$ROOT" -type f -name '*.sh' -print0)
}
status_test() { "$ROOT/bin/vpsg" status >/dev/null; }
firewall_safety_test() {
  "$ROOT/bin/vpsg" firewall plan >/dev/null 2>&1 || [[ $? -eq 30 ]]
}
scope_test() {
  # shellcheck source=../core/common.sh
  . "$ROOT/core/common.sh"
  # shellcheck source=../core/inspect.sh
  . "$ROOT/core/inspect.sh"
  [[ "$(inspect_scope 0.0.0.0)" == wildcard ]]
  [[ "$(inspect_scope ::)" == wildcard ]]
  [[ "$(inspect_scope 127.0.0.1)" == loopback ]]
  [[ "$(inspect_scope 10.0.0.2)" == private ]]
  [[ "$(inspect_scope 203.0.113.7)" == specific ]]
}
transaction_state_test() (
  set -euo pipefail
  export VPSG_TX_SCHEDULER=manual
  # shellcheck source=../core/common.sh
  . "$ROOT/core/common.sh"
  # shellcheck source=../core/router.sh
  . "$ROOT/core/router.sh"
  # shellcheck source=../core/transaction.sh
  . "$ROOT/core/transaction.sh"
  require_root() { return 0; }
  local id
  id="$(tx_begin ssh 60)"
  [[ -n "$id" ]]
  tx_status "$id" | grep -q '状态: pending'
  tx_commit "$id" >/dev/null
  [[ "$(_tx_state_get "$VPSG_TX_DIR/$id" status)" == committed ]]
)
exposure_command_test() {
  if command -v ss >/dev/null 2>&1; then "$ROOT/bin/vpsg" exposure json | python3 -m json.tool >/dev/null; else return 0; fi
}
baseline_list_test() { "$ROOT/bin/vpsg" baseline list | grep -q '暂无安全基线'; }

run_test "help" help_test
run_test "version" version_test
run_test "module discovery" modules_test
run_test "bash syntax" syntax_test
run_test "read-only status" status_test
run_test "firewall safe plan" firewall_safety_test
run_test "exposure scope classification" scope_test
run_test "safe transaction state machine" transaction_state_test
run_test "exposure json" exposure_command_test
run_test "baseline list" baseline_list_test

echo "Tests: $pass passed, $fail failed"
(( fail == 0 ))
