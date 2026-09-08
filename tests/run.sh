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
pass=0; fail=0
run_test() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; pass=$((pass+1)); else echo "FAIL: $name"; fail=$((fail+1)); fi; }
help_test() { local out; out="$(bash "$ROOT/bin/vpsg" --help)"; grep -q 'exposure scan' <<<"$out"; }
version_test() { [[ "$(bash "$ROOT/bin/vpsg" --version)" == "0.3.0" ]]; }
modules_test() { local out; out="$(bash "$ROOT/bin/vpsg" module list)"; for m in baseline bbr docker drift exposure fail2ban firewall incident network panel ssh swap system users watch; do grep -qx "$m" <<<"$out" || return 1; done; }
syntax_test() { local f; while IFS= read -r -d '' f; do bash -n "$f" || return 1; done < <(find "$ROOT" -type f -name '*.sh' -print0); bash -n "$ROOT/bin/vpsg"; }
status_test() { bash "$ROOT/bin/vpsg" status >/dev/null; }
router_mode_test() { chmod -x "$ROOT/modules/builtin/exposure/module.sh"; bash "$ROOT/bin/vpsg" exposure json >/dev/null 2>&1 || [[ $? -eq 20 ]]; }
scope_test() { . "$ROOT/core/common.sh"; . "$ROOT/core/inspect.sh"; [[ "$(inspect_scope 0.0.0.0)" == wildcard && "$(inspect_scope 127.0.0.1)" == loopback && "$(inspect_scope 10.0.0.2)" == private ]]; }
risk_test() { . "$ROOT/core/common.sh"; . "$ROOT/core/inspect.sh"; . <(sed '/^action=/,$d' "$ROOT/modules/builtin/exposure/module.sh"); [[ "$(risk_for_listener 2375 wildcard inactive '')" == CRITICAL* && "$(risk_for_listener 443 wildcard allow '')" == LOW* ]]; }
transaction_test() ( export VPSG_TX_SCHEDULER=manual; . "$ROOT/core/common.sh"; . "$ROOT/core/platform.sh"; . "$ROOT/core/router.sh"; . "$ROOT/core/transaction.sh"; require_root(){ return 0; }; _tx_precheck(){ return 0; }; _tx_postverify(){ return 0; }; id="$(tx_begin ssh 60)"; tx_status "$id" | grep -q pending; tx_commit "$id" >/dev/null; tx_history 5 | grep -q "$id"; )
users_test() { local out; out="$(bash "$ROOT/bin/vpsg" users list)"; grep -q 'USER' <<<"$out"; }
panel_test() { bash "$ROOT/bin/vpsg" panel status | grep -q '1Panel'; }
watch_test() { bash "$ROOT/bin/vpsg" watch status | grep -q 'VPS Guard Watch'; }
baseline_list_test() { bash "$ROOT/bin/vpsg" baseline list | grep -q '暂无安全基线'; }
symlink_entry_test() { local link="${TMPDIR:-/tmp}/vpsg-link-$$"; ln -sf "$ROOT/bin/vpsg" "$link"; [[ "$("$link" --version)" == "0.3.0" ]]; rm -f "$link"; }
run_test help help_test; run_test version version_test; run_test "module discovery" modules_test; run_test "bash syntax" syntax_test; run_test "read-only status" status_test; run_test "router works without executable bit" router_mode_test; run_test "exposure scope" scope_test; run_test "exposure risk" risk_test; run_test "safe transaction history" transaction_test; run_test "users list" users_test; run_test "panel status" panel_test; run_test "watch status" watch_test; run_test "baseline list" baseline_list_test; run_test "symlink entrypoint" symlink_entry_test
echo "Tests: $pass passed, $fail failed"; (( fail == 0 ))
