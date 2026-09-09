#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/testlib.sh"

case_scope() ( new_case_env scope >/dev/null; source_inspect; [[ "$(inspect_scope 0.0.0.0)" == wildcard && "$(inspect_scope 127.0.0.1)" == loopback && "$(inspect_scope 10.1.2.3)" == private && "$(inspect_scope 100.64.1.1)" == private && "$(inspect_scope 100.127.255.1)" == private && "$(inspect_scope 100.128.0.1)" == specific && "$(inspect_scope '::ffff:127.0.0.1')" == loopback ]]; )
case_docker_multi_binding() ( local base out; new_case_env dockermulti >/dev/null; base="$CASE_BASE"; source_inspect; make_mock "$base" docker <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
 info) exit 0;;
 ps) echo cid1;;
 inspect) printf '/web\t80/tcp\t0.0.0.0\t8080\n/web\t443/tcp\t::\t8443\n';;
 *) exit 0;;
esac
MOCK
 out="$(inspect_docker_ports)"; [[ "$(wc -l <<<"$out")" -eq 2 ]] && assert_contains "$out" $'web\ttcp\t0.0.0.0\t8080\t80\twildcard' && assert_contains "$out" $'web\ttcp\t::\t8443\t443\twildcard'; )
case_docker_restricted() ( local base; new_case_env dockerrestricted >/dev/null; base="$CASE_BASE"; source_inspect; make_mock "$base" docker <<'MOCK'
#!/usr/bin/env bash
[[ "${1:-}" == info ]] && exit 1
exit 0
MOCK
 [[ "$(inspect_docker_visibility 2>/dev/null || true)" == restricted ]]; )
case_listener_process_stable() (
  local base out
  new_case_env listenerstable >/dev/null; base="$CASE_BASE"; source_inspect
  make_mock "$base" ss <<'MOCK'
#!/usr/bin/env bash
printf 'tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1234,fd=3))\n'
MOCK
  out="$(inspect_listeners)"
  assert_contains "$out" $'tcp\t0.0.0.0\t22\twildcard\tsshd' && assert_not_contains "$out" 'pid='
)
case_docker_state_stable() (
  local base out
  new_case_env dockerstate >/dev/null; base="$CASE_BASE"; source_inspect
  make_mock "$base" docker <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
  info) exit 0;;
  ps) printf 'web\tnginx:latest\trunning\n';;
  *) exit 0;;
esac
MOCK
  out="$(inspect_docker_state)"
  [[ "$out" == $'web\tnginx:latest\trunning' ]]
)
case_authorized_keys_custom_home() (
  local base home out
  new_case_env customhome >/dev/null; base="$CASE_BASE"; source_inspect; home="$base/custom-home"; mkdir -p "$home/.ssh"; printf 'ssh-ed25519 AAAA test\n' > "$home/.ssh/authorized_keys"
  make_mock "$base" getent <<MOCK
#!/usr/bin/env bash
if [[ "\${1:-}" == passwd ]]; then printf 'alice:x:1000:1000::${home}:/bin/bash\\n'; exit 0; fi
/usr/bin/getent "\$@"
MOCK
  out="$(inspect_authorized_keys)"
  assert_contains "$out" "$home/.ssh/authorized_keys"
)
case_snapshot_tamper() ( local base snap; new_case_env snaptamper >/dev/null; base="$CASE_BASE"; source_inspect; snap="$base/snap"; mkdir -p "$snap"; printf 'schema=2\n' > "$snap/manifest"; printf 'listeners\tok\n' > "$snap/collection.tsv"; printf 'a\n' > "$snap/listeners.tsv"; snapshot_seal "$snap" && snapshot_verify "$snap" && printf 'b\n' >> "$snap/listeners.tsv" && ! snapshot_verify "$snap"; )
case_snapshot_extra_file() ( local base snap; new_case_env snapextra >/dev/null; base="$CASE_BASE"; source_inspect; snap="$base/snap"; mkdir -p "$snap"; printf 'schema=2\n' > "$snap/manifest"; printf 'listeners\tok\n' > "$snap/collection.tsv"; snapshot_seal "$snap" && snapshot_verify "$snap"; printf x > "$snap/injected"; ! snapshot_verify "$snap"; )
case_snapshot_incomplete() ( local base snap; new_case_env snapinc >/dev/null; base="$CASE_BASE"; source_inspect; snap="$base/snap"; mkdir -p "$snap"; printf 'a\tok\nb\tincomplete(rc=20)\nc\tincomplete(rc=30)\n' > "$snap/collection.tsv"; [[ "$(snapshot_incomplete_count "$snap")" == 2 ]]; )
case_snapshot_real_capture() ( local base snap; new_case_env snapreal >/dev/null; base="$CASE_BASE"; source_inspect; snap="$base/snap"; snapshot_capture "$snap" && snapshot_seal "$snap" && snapshot_verify "$snap" && [[ -r "$snap/collection.tsv" ]]; )

case_exposure_sensitive() ( new_case_env exrisk >/dev/null; source_module_defs exposure; [[ "$(risk_for_record 6379 wildcard host deny Redis general 22)" == CRITICAL\|* ]] && [[ "$(risk_for_record 2375 private host inactive 'Docker API' general 22)" == HIGH\|* ]]; )
case_service_hint_no_dynamic_scope() ( new_case_env servicehint >/dev/null; source_module_defs exposure; unset process 2>/dev/null || true; [[ "$(service_hint 9999 redis-server)" == Redis ]]; )
case_exposure_profile() ( new_case_env exprofile >/dev/null; source_module_defs exposure; [[ "$(risk_for_record 443 wildcard host allow Web web 22)" == LOW\|* ]] && [[ "$(risk_for_record 22 wildcard host allow SSH web 22)" == MEDIUM\|* ]]; )
case_exposure_container_port_service() ( local base listeners docker records seen row; new_case_env excport >/dev/null; base="$CASE_BASE"; source_module_defs exposure; profile_get(){ echo general; }; ssh_primary_port(){ echo 22; }; inspect_ufw_port_policy(){ echo inactive; }; listeners="$base/listeners"; docker="$base/docker"; records="$base/records"; seen="$base/seen"; : > "$listeners"; printf 'db\ttcp\t0.0.0.0\t13306\t3306\twildcard\n' > "$docker"; _build_records "$listeners" "$docker" "$records" "$seen"; row="$(cat "$records")"; assert_contains "$row" $'\tMySQL\tHIGH\t'; )
case_exposure_ufw_not_false_safe() ( new_case_env exufw >/dev/null; source_module_defs exposure; [[ "$(risk_for_record 6379 wildcard docker deny Redis general 22)" == CRITICAL\|* ]]; )
case_json_escape() ( new_case_env jsonescape >/dev/null; source_module_defs exposure; [[ "$(_json_escape $'a"b\\c\n')" == 'a\"b\\c\n' ]]; )

case_drift_public_redis() ( local base b a out; new_case_env driftredis >/dev/null; base="$CASE_BASE"; source_module_defs drift; b="$base/b"; a="$base/a"; : > "$b"; printf 'tcp\t0.0.0.0\t6379\twildcard\tredis-server\n' > "$a"; out="$(_diff_listeners "$b" "$a")"; assert_contains "$out" '[CRITICAL] 新增监听端口 6379/tcp'; )
case_drift_private_redis() ( local base b a out; new_case_env driftprivate >/dev/null; base="$CASE_BASE"; source_module_defs drift; b="$base/b"; a="$base/a"; : > "$b"; printf 'tcp\t10.0.0.2\t6379\tprivate\tredis-server\n' > "$a"; out="$(_diff_listeners "$b" "$a")"; assert_contains "$out" '[HIGH]'; )
case_drift_removal_info() ( local base b a out; new_case_env driftremove >/dev/null; base="$CASE_BASE"; source_module_defs drift; b="$base/b"; a="$base/a"; printf 'tcp\t0.0.0.0\t9999\twildcard\tx\n' > "$b"; : > "$a"; out="$(_diff_listeners "$b" "$a")"; assert_contains "$out" '[INFO] 监听端口消失'; )
case_drift_collection_loss() ( local base b a out; new_case_env driftcoverage >/dev/null; base="$CASE_BASE"; source_module_defs drift; b="$base/b"; a="$base/a"; printf 'docker-ports\tok\n' > "$b"; printf 'docker-ports\tincomplete(rc=30)\n' > "$a"; out="$(_diff_collection "$b" "$a")"; assert_contains "$out" '[MEDIUM] 采集覆盖下降'; )
case_drift_docker_container_semantics() ( local base b a out; new_case_env driftdocker >/dev/null; base="$CASE_BASE"; source_module_defs drift; b="$base/b"; a="$base/a"; : > "$b"; printf 'db\ttcp\t0.0.0.0\t13306\t3306\twildcard\n' > "$a"; out="$(_diff_docker_ports "$b" "$a")"; assert_contains "$out" '[HIGH] Docker 新增发布端口 13306/tcp'; )
case_drift_key_change() ( local base b a out; new_case_env driftkeys >/dev/null; base="$CASE_BASE"; source_module_defs drift; b="$base/b"; a="$base/a"; printf '/root/.ssh/authorized_keys\t1\taaa\n' > "$b"; printf '/root/.ssh/authorized_keys\t2\tbbb\n' > "$a"; out="$(_diff_authorized_keys "$b" "$a")"; assert_contains "$out" '[HIGH] SSH authorized_keys 变化'; )

case_baseline_name_path_guard() (
  local base
  new_case_env basenameguard >/dev/null; base="$CASE_BASE"; source_module_defs baseline
  ! _valid_name '.' && ! _valid_name '..' && ! _valid_name '-hidden' && _valid_name 'prod.web-1'
)
case_drift_report_path_guard() (
  local base
  new_case_env reportguard >/dev/null; base="$CASE_BASE"; source_module_defs drift
  ! _valid_name '.' && ! _valid_name '..' && ! _valid_report_id '.' && ! _valid_report_id '..' && _valid_report_id '20260909-120000-default-123'
)
case_tx_prepare_failure_is_terminal() (
  local base rc=0 id dir active_rc=0
  new_case_env txpreparefail >/dev/null; base="$CASE_BASE"; _tx_env "$base"; export VPSG_TEST_SESSION_FINGERPRINT=console; source_transaction
  require_root(){ return 0; }; _tx_precheck(){ return 0; }; ssh_primary_port(){ echo 22; }; _tx_snapshot_ssh(){ return 40; }
  tx_begin ssh 60 >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 40 ]] || return 1
  id="$(find "$VPSG_TX_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | head -1)"
  _tx_valid_id "$id" || return 1; dir="$VPSG_TX_DIR/$id"
  [[ "$(_tx_state_get "$dir" status)" == prepare_failed && ! -e "$VPSG_TX_CURRENT" ]] || return 1
  _tx_active_id >/dev/null 2>&1 || active_rc=$?
  [[ $active_rc -eq 1 ]]
)
case_tx_rollback_state_is_durable() (
  local base id txdir content
  new_case_env txdurable >/dev/null; base="$CASE_BASE"; _tx_env "$base"; source_transaction
  id='20260909-120000-123-1abc'; txdir="$base/direct-tx"; mkdir -p "$txdir"
  _tx_write_rollback_script "$txdir" ssh "$id" || return 1
  content="$(cat "$txdir/rollback.sh")"
  assert_contains "$content" 'sync -f -- "$DIR/state"'
)

_tx_env() {
  local base="$1"
  export VPSG_TX_DIR="$base/state/transactions" VPSG_TX_CURRENT="$base/state/transactions/current" VPSG_TX_SCHEDULER=manual
  export VPSG_TX_SSH_CONF="$base/ssh/00-vps-guard.conf" VPSG_TX_SSH_LEGACY_CONF="$base/ssh/90-vps-guard.conf" VPSG_TX_SSH_MAIN_CONFIG="$base/ssh/sshd_config"
  export VPSG_TX_UFW_DIR="$base/ufw" VPSG_TX_UFW_DEFAULT="$base/default-ufw"
}

case_tx_rollback_sync_failure_restores_retryable_state() (
  local base id dir rc=0
  new_case_env txrollbacksync >/dev/null; base="$CASE_BASE"; _tx_env "$base"; source_transaction
  id='20260909-130000-321-2abc'; dir="$VPSG_TX_DIR/$id"
  mkdir -p "$dir/snapshot" "$VPSG_SYSTEMD_DIR" "$(dirname "$VPSG_TX_SSH_CONF")"
  printf 'status=pending
module=ssh
' > "$dir/state"
  printf 'absent
' > "$dir/snapshot/ssh-00.presence"
  printf 'absent
' > "$dir/snapshot/ssh-90.presence"
  _tx_write_rollback_script "$dir" ssh "$id" || return 1
  make_mock "$base" sync <<'MOCK'
#!/usr/bin/env bash
count_file="$CASE_BASE/sync.count"
count=0; [[ -r "$count_file" ]] && count="$(cat "$count_file")"
count=$((count+1)); printf '%s
' "$count" > "$count_file"
((count==1)) && exit 1
exit 0
MOCK
  /bin/bash "$dir/rollback.sh" >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 40 && "$(_tx_state_get "$dir" status)" == pending ]]
)
case_tx_id_guard() ( local base; new_case_env txid >/dev/null; base="$CASE_BASE"; _tx_env "$base"; source_transaction; _tx_valid_id '20260909-120000-123-1abc' && ! _tx_valid_id '../../etc' && ! _tx_dir_for '../../etc' >/dev/null 2>&1; )
case_tx_same_session_rejected() ( local base id dir rc=0; new_case_env txsame >/dev/null; base="$CASE_BASE"; _tx_env "$base"; export VPSG_TEST_SESSION_FINGERPRINT='ssh:100:1'; source_transaction; require_root(){ return 0; }; _tx_precheck(){ return 0; }; _tx_postverify(){ return 0; }; ssh_primary_port(){ echo 22; }; id="$(tx_begin ssh 60)" || return 1; dir="$(_tx_dir_for "$id")"; _tx_state_set "$dir" status pending; tx_commit "$id" >/dev/null 2>&1 || rc=$?; [[ $rc -eq 30 && "$(_tx_state_get "$dir" status)" == pending ]]; )
case_tx_new_session_commit() ( local base id dir; new_case_env txnew >/dev/null; base="$CASE_BASE"; _tx_env "$base"; export VPSG_TEST_SESSION_FINGERPRINT='ssh:100:1'; source_transaction; require_root(){ return 0; }; _tx_precheck(){ return 0; }; _tx_postverify(){ return 0; }; ssh_primary_port(){ echo 22; }; id="$(tx_begin ssh 60)" || return 1; dir="$(_tx_dir_for "$id")"; _tx_state_set "$dir" status pending; export VPSG_TEST_SESSION_FINGERPRINT='ssh:200:2'; tx_commit "$id" >/dev/null && [[ "$(_tx_state_get "$dir" status)" == committed && ! -e "$VPSG_TX_CURRENT" ]]; )
case_tx_console_requires_confirm() ( local base id dir rc=0; new_case_env txconsole >/dev/null; base="$CASE_BASE"; _tx_env "$base"; export VPSG_TEST_SESSION_FINGERPRINT='ssh:100:1'; source_transaction; require_root(){ return 0; }; _tx_precheck(){ return 0; }; _tx_postverify(){ return 0; }; ssh_primary_port(){ echo 22; }; id="$(tx_begin ssh 60)" || return 1; dir="$(_tx_dir_for "$id")"; _tx_state_set "$dir" status pending; export VPSG_TEST_SESSION_FINGERPRINT=console; tx_commit "$id" >/dev/null 2>&1 || rc=$?; [[ $rc -eq 30 ]] || return 1; tx_commit "$id" --console-confirm >/dev/null; )
case_tx_single_active() ( local base id rc=0; new_case_env txactive >/dev/null; base="$CASE_BASE"; _tx_env "$base"; export VPSG_TEST_SESSION_FINGERPRINT=console; source_transaction; require_root(){ return 0; }; _tx_precheck(){ return 0; }; ssh_primary_port(){ echo 22; }; id="$(tx_begin ssh 60)" || return 1; tx_begin firewall 60 >/dev/null 2>&1 || rc=$?; [[ -n "$id" && $rc -eq 30 ]]; )
case_tx_extend() ( local base id dir old new; new_case_env txextend >/dev/null; base="$CASE_BASE"; _tx_env "$base"; export VPSG_TEST_SESSION_FINGERPRINT=console; source_transaction; require_root(){ return 0; }; _tx_precheck(){ return 0; }; ssh_primary_port(){ echo 22; }; id="$(tx_begin ssh 60)" || return 1; dir="$(_tx_dir_for "$id")"; _tx_state_set "$dir" status pending; old="$(_tx_state_get "$dir" deadline_epoch)"; tx_extend "$id" 300 >/dev/null; new="$(_tx_state_get "$dir" deadline_epoch)"; [[ "$new" -gt "$old" ]]; )
case_tx_rollback_script_paths() ( local base id dir content; new_case_env txpaths >/dev/null; base="$CASE_BASE"; _tx_env "$base"; export VPSG_TEST_SESSION_FINGERPRINT=console; source_transaction; require_root(){ return 0; }; _tx_precheck(){ return 0; }; ssh_primary_port(){ echo 22; }; id="$(tx_begin ssh 60)" || return 1; dir="$(_tx_dir_for "$id")"; content="$(cat "$dir/rollback.sh")"; assert_contains "$content" "$base/ssh/00-vps-guard.conf" && assert_contains "$content" "$base/systemd"; )
case_tx_rollback_builder_independent_scope() ( local base id txdir; new_case_env txbuilder >/dev/null; base="$CASE_BASE"; _tx_env "$base"; source_transaction; id='20260909-120000-123-1abc'; txdir="$base/direct-tx"; mkdir -p "$txdir"; unset dir 2>/dev/null || true; _tx_write_rollback_script "$txdir" ssh "$id"; [[ -f "$txdir/rollback.sh" ]]; )
case_tx_auto_rollback() ( local base id dir status; new_case_env txrollback >/dev/null; base="$CASE_BASE"; _tx_env "$base"; export VPSG_TEST_SESSION_FINGERPRINT=console; source_transaction; require_root(){ return 0; }; _tx_precheck(){ return 0; }; ssh_primary_port(){ echo 22; }; make_mock "$base" sshd <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
 make_mock "$base" systemctl <<'MOCK'
#!/usr/bin/env bash
[[ "${1:-}" == is-active ]] && exit 1
exit 0
MOCK
 id="$(tx_begin ssh 60)" || return 1; dir="$(_tx_dir_for "$id")"; _tx_state_set "$dir" status pending; /bin/bash "$dir/rollback.sh" || return 1; status="$(_tx_state_get "$dir" status)"; [[ "$status" == rolled_back && ! -e "$VPSG_TX_CURRENT" ]]; )


case_tx_malformed_current_fail_closed() (
  local base rc=0 before
  new_case_env txbadcurrent >/dev/null; base="$CASE_BASE"; _tx_env "$base"; source_transaction
  require_root(){ return 0; }; _tx_precheck(){ return 0; }; ssh_primary_port(){ echo 22; }
  mkdir -p "$VPSG_TX_DIR"; printf '../../etc\n' > "$VPSG_TX_CURRENT"; before="$(cat "$VPSG_TX_CURRENT")"
  tx_begin ssh 60 >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 70 && "$(cat "$VPSG_TX_CURRENT")" == "$before" ]]
)
case_tx_terminal_current_is_cleaned() (
  local base id dir rc=0
  new_case_env txterminal >/dev/null; base="$CASE_BASE"; _tx_env "$base"; source_transaction
  id='20260909-120000-123-1abc'; dir="$VPSG_TX_DIR/$id"; mkdir -p "$dir"; printf 'status=committed\n' > "$dir/state"; printf '%s\n' "$id" > "$VPSG_TX_CURRENT"
  _tx_active_id >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 1 && ! -e "$VPSG_TX_CURRENT" ]]
)
case_tx_orphan_active_is_discovered() (
  local base id dir out rc=0
  new_case_env txorphan >/dev/null; base="$CASE_BASE"; _tx_env "$base"; source_transaction
  require_root(){ return 0; }; _tx_precheck(){ return 0; }; ssh_primary_port(){ echo 22; }
  id='20260909-120001-123-1abc'; dir="$VPSG_TX_DIR/$id"; mkdir -p "$dir"; printf 'status=pending\nmodule=ssh\n' > "$dir/state"
  out="$(_tx_active_id)" || return 1
  [[ "$out" == "$id" ]] || return 1
  tx_begin firewall 60 >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 30 && ! -e "$VPSG_TX_CURRENT" ]]
)
case_tx_orphan_resolve_without_current() (
  local base id dir out
  new_case_env txresolveorphan >/dev/null; base="$CASE_BASE"; _tx_env "$base"; source_transaction
  id='20260909-120002-123-1abc'; dir="$VPSG_TX_DIR/$id"; mkdir -p "$dir"; printf 'status=apply_failed\nmodule=ssh\n' > "$dir/state"
  out="$(_tx_resolve_id)" || return 1
  [[ "$out" == "$id" ]]
)
case_tx_multiple_orphans_fail_closed() (
  local base id1 id2 rc=0
  new_case_env txmulti >/dev/null; base="$CASE_BASE"; _tx_env "$base"; source_transaction
  id1='20260909-120003-123-1abc'; id2='20260909-120004-123-1abc'
  mkdir -p "$VPSG_TX_DIR/$id1" "$VPSG_TX_DIR/$id2"
  printf 'status=pending\n' > "$VPSG_TX_DIR/$id1/state"
  printf 'status=rollback_failed\n' > "$VPSG_TX_DIR/$id2/state"
  _tx_active_id >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 70 ]]
)
case_tx_foreign_systemd_unit_rejected() (
  local base id dir unit service rc=0
  new_case_env txforeignunit >/dev/null; base="$CASE_BASE"; _tx_env "$base"; export VPSG_TX_SCHEDULER=systemd; source_transaction
  id='20260909-120008-123-1abc'; dir="$VPSG_TX_DIR/$id"; mkdir -p "$dir" "$VPSG_SYSTEMD_DIR"
  printf 'status=applying\ndeadline_epoch=%s\n' "$(( $(date +%s) + 60 ))" > "$dir/state"
  make_mock "$base" systemctl <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  unit="$(_tx_unit_name "$id")"; service="$VPSG_SYSTEMD_DIR/$unit.service"
  printf '[Unit]\nDescription=foreign\n' > "$service"
  _tx_schedule "$dir" "$id" >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 70 ]] || return 1
  grep -Fq 'Description=foreign' "$service"
)

case_tx_commit_timer_cancel_failure_rearms() (
  local base id dir rc=0
  new_case_env txcommitcancel >/dev/null; base="$CASE_BASE"; _tx_env "$base"; export VPSG_TEST_SESSION_FINGERPRINT='ssh:100:1'; source_transaction
  require_root(){ return 0; }; _tx_precheck(){ return 0; }; _tx_postverify(){ return 0; }; ssh_primary_port(){ echo 22; }
  id="$(tx_begin ssh 60)" || return 1; dir="$(_tx_dir_for "$id")"; _tx_state_set "$dir" status pending
  export VPSG_TEST_SESSION_FINGERPRINT='ssh:200:2'
  _tx_cancel_timer_strict(){ return 40; }
  _tx_schedule(){ : > "$dir/rearmed"; return 0; }
  tx_commit "$id" >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 40 && "$(_tx_state_get "$dir" status)" == pending && -f "$dir/rearmed" && -e "$VPSG_TX_CURRENT" ]]
)

case_tx_commit_state_persist_failure_rearms() (
  local base id dir rc=0
  new_case_env txcommitseal >/dev/null; base="$CASE_BASE"; _tx_env "$base"; export VPSG_TEST_SESSION_FINGERPRINT='ssh:100:1'; source_transaction
  require_root(){ return 0; }; _tx_precheck(){ return 0; }; _tx_postverify(){ return 0; }; ssh_primary_port(){ echo 22; }
  id="$(tx_begin ssh 60)" || return 1; dir="$(_tx_dir_for "$id")"; _tx_state_set "$dir" status pending || return 1
  export VPSG_TEST_SESSION_FINGERPRINT='ssh:200:2'
  _tx_cancel_timer_strict(){ return 0; }
  _tx_schedule(){ : > "$dir/rearmed-after-seal-failure"; return 0; }
  durable_sync_path() {
    local path="$1"
    if [[ "$path" == "$dir/state" ]] && grep -qx 'status=committed' "$path" 2>/dev/null; then return 40; fi
    return 0
  }
  tx_commit "$id" >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 40 && "$(_tx_state_get "$dir" status)" == commit_pending && -f "$dir/rearmed-after-seal-failure" && -e "$VPSG_TX_CURRENT" ]]
)
case_tx_commit_pending_is_active() (
  local base id dir out
  new_case_env txcommitpending >/dev/null; base="$CASE_BASE"; _tx_env "$base"; source_transaction
  id='20260909-120007-123-1abc'; dir="$VPSG_TX_DIR/$id"; mkdir -p "$dir"; printf 'status=commit_pending\nmodule=ssh\n' > "$dir/state"
  out="$(_tx_active_id)" || return 1
  [[ "$out" == "$id" ]]
)

case_tx_terminal_pointer_recovers_orphan_active() (
  local base terminal active out
  new_case_env txterminalorphan >/dev/null; base="$CASE_BASE"; _tx_env "$base"; source_transaction
  terminal='20260909-120005-123-1abc'; active='20260909-120006-123-1abc'
  mkdir -p "$VPSG_TX_DIR/$terminal" "$VPSG_TX_DIR/$active"
  printf 'status=committed\n' > "$VPSG_TX_DIR/$terminal/state"
  printf 'status=pending\n' > "$VPSG_TX_DIR/$active/state"
  printf '%s\n' "$terminal" > "$VPSG_TX_CURRENT"
  out="$(_tx_active_id)" || return 1
  [[ "$out" == "$active" && ! -e "$VPSG_TX_CURRENT" ]]
)

case_profile_invalid_falls_back_general() (
  local base out
  new_case_env profileinvalid >/dev/null; base="$CASE_BASE"; source_module_defs exposure
  mkdir -p "$VPSG_ETC_DIR"; printf 'web\nmalicious-extra\n' > "$PROFILE_FILE"
  out="$(profile_get 2>/dev/null)"; [[ "$out" == web ]] || return 1
  printf 'not-a-profile\n' > "$PROFILE_FILE"
  out="$(profile_get 2>/dev/null)"; [[ "$out" == general ]] || return 1
  rm -f "$PROFILE_FILE"; ln -s "$base/other" "$PROFILE_FILE"; printf 'proxy\n' > "$base/other"
  out="$(profile_get 2>/dev/null)"; [[ "$out" == general ]]
)

run_test 'scope classification including CGNAT' case_scope
run_test 'Docker multiple published bindings' case_docker_multi_binding
run_test 'Docker visibility restricted' case_docker_restricted
run_test 'listener process identity is stable' case_listener_process_stable
run_test 'Docker lifecycle state is stable' case_docker_state_stable
run_test 'authorized_keys supports custom home paths' case_authorized_keys_custom_home
run_test 'snapshot content tamper detection' case_snapshot_tamper
run_test 'snapshot file-set tamper detection' case_snapshot_extra_file
run_test 'snapshot incomplete counter' case_snapshot_incomplete
run_test 'real snapshot capture + seal' case_snapshot_real_capture
run_test 'Exposure sensitive service risk' case_exposure_sensitive
run_test 'Exposure service hint independent scope' case_service_hint_no_dynamic_scope
run_test 'Exposure profile expectations' case_exposure_profile
run_test 'Exposure invalid/symlink profile fails safe' case_profile_invalid_falls_back_general
run_test 'Exposure uses Docker container port semantics' case_exposure_container_port_service
run_test 'Docker/UFW no false-safety downgrade' case_exposure_ufw_not_false_safe
run_test 'Exposure JSON escaping' case_json_escape
run_test 'Drift public Redis CRITICAL' case_drift_public_redis
run_test 'Drift private Redis HIGH' case_drift_private_redis
run_test 'Drift service removal INFO' case_drift_removal_info
run_test 'Drift collection coverage loss' case_drift_collection_loss
run_test 'Drift Docker container-port semantics' case_drift_docker_container_semantics
run_test 'Drift authorized_keys change HIGH' case_drift_key_change
run_test 'Baseline name path guard' case_baseline_name_path_guard
run_test 'Drift report path guard' case_drift_report_path_guard
run_test 'Safe Change pre-apply failure is terminal' case_tx_prepare_failure_is_terminal
run_test 'Safe Change rollback state uses persistence barrier' case_tx_rollback_state_is_durable
run_test 'Safe Change rollback sync failure restores retryable state' case_tx_rollback_sync_failure_restores_retryable_state
run_test 'Safe Change transaction ID guard' case_tx_id_guard
run_test 'Safe Change malformed current fails closed' case_tx_malformed_current_fail_closed
run_test 'Safe Change terminal current is cleaned' case_tx_terminal_current_is_cleaned
run_test 'Safe Change orphan active is discovered' case_tx_orphan_active_is_discovered
run_test 'Safe Change orphan active resolves without current' case_tx_orphan_resolve_without_current
run_test 'Safe Change multiple orphan actives fail closed' case_tx_multiple_orphans_fail_closed
run_test 'Safe Change refuses foreign systemd rollback unit' case_tx_foreign_systemd_unit_rejected
run_test 'Safe Change commit timer cancellation failure re-arms' case_tx_commit_timer_cancel_failure_rearms
run_test 'Safe Change commit seal failure re-arms rollback' case_tx_commit_state_persist_failure_rearms
run_test 'Safe Change commit_pending stays active' case_tx_commit_pending_is_active
run_test 'Safe Change terminal pointer recovers orphan active' case_tx_terminal_pointer_recovers_orphan_active
run_test 'Safe Change same SSH session rejected' case_tx_same_session_rejected
run_test 'Safe Change new SSH session commit' case_tx_new_session_commit
run_test 'Safe Change console confirmation' case_tx_console_requires_confirm
run_test 'Safe Change single active transaction' case_tx_single_active
run_test 'Safe Change deadline extend' case_tx_extend
run_test 'Safe Change rollback paths isolated' case_tx_rollback_script_paths
run_test 'Safe Change rollback builder independent scope' case_tx_rollback_builder_independent_scope
run_test 'Safe Change automatic rollback state' case_tx_auto_rollback
