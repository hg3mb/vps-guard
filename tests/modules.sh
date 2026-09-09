#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/testlib.sh"

case_users_list() ( new_case_env users >/dev/null; local out; out="$(bash "$ROOT/bin/vpsg" users list)"; assert_contains "$out" 'PASSWORD' && assert_contains "$out" 'SSH_KEYS'; )
case_users_password_disable_requires_key() (
  local base rc=0
  new_case_env userpassnokey >/dev/null; base="$CASE_BASE"; source_module_defs users
  make_mock "$base" getent <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == passwd && "$2" == testuser ]] && { printf 'testuser:x:1001:1001::%s/home:/bin/bash\n' "$CASE_BASE"; exit 0; }
exit 2
MOCK
  password_disable testuser >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 30 ]]
)

case_users_password_disable_preserves_pubkey_path() (
  local base
  new_case_env userpasskey >/dev/null; base="$CASE_BASE"; source_module_defs users
  mkdir -p "$base/home/.ssh"; printf 'ssh-ed25519 AAAATEST example\n' > "$base/home/.ssh/authorized_keys"
  make_mock "$base" getent <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == passwd && "$2" == testuser ]] && { printf 'testuser:x:1001:1001::%s/home:/bin/bash\n' "$CASE_BASE"; exit 0; }
exit 2
MOCK
  make_mock "$base" usermod <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$CASE_BASE/usermod.args"
MOCK
  password_disable testuser >/dev/null || return 1
  [[ "$(cat "$base/usermod.args")" == '-p *NP* testuser' ]]
)

case_panel_plan() ( new_case_env panel >/dev/null; local out; out="$(bash "$ROOT/bin/vpsg" panel plan)"; assert_contains "$out" 'SHA-256' && assert_contains "$out" 'bash -n' && assert_contains "$out" '不会 curl | bash'; )
case_panel_sanitized_environment() ( new_case_env panelenv >/dev/null; local text; text="$(cat "$ROOT/modules/builtin/panel/module.sh")"; assert_contains "$text" '/usr/bin/env -i' && assert_contains "$text" 'HOME=/root'; )
case_network_route_injection() ( new_case_env routeinj >/dev/null; bash "$ROOT/bin/vpsg" network route '--help' >/dev/null 2>&1; [[ $? -eq 64 ]]; )
case_network_external_https() ( new_case_env exturl >/dev/null; source_module_defs network; [[ "$YABS_URL" == https://* && "$REGION_URL" == https://* ]]; )
case_network_root_downgrade_readable() (
  local script out
  [[ ${EUID:-$(id -u)} -eq 0 ]] || return 0
  new_case_env extdowngrade >/dev/null; source_module_defs network
  script="$(mktemp /var/tmp/vpsg-test-external.XXXXXX)" || return 1
  trap 'rm -f -- "$script"' EXIT
  printf '#!/usr/bin/env bash\nid -u\nprintf "%%s\\n" "${VPSG_SECRET_TEST-unset}"\n' > "$script"; chmod 600 "$script"
  VPSG_SECRET_TEST=should-not-leak SUDO_USER=nobody out="$(_run_external_as_user "$script")" || return 1
  [[ "$out" == "$(id -u nobody)"$'\n'unset && "$(stat -c '%a' "$script")" == 600 ]]
)

case_docker_repo_symlink_rejected() (
  local base rc=0
  new_case_env dockersymlinkrepo >/dev/null; base="$CASE_BASE"
  export VPSG_APT_KEYRINGS_DIR="$base/keyrings" VPSG_APT_SOURCES_DIR="$base/sources"
  mkdir -p "$VPSG_APT_KEYRINGS_DIR" "$VPSG_APT_SOURCES_DIR"; source_module_defs docker
  printf keep > "$base/target"; ln -s "$base/target" "$KEY"
  _repo_paths_safe >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 70 && "$(cat "$base/target")" == keep ]]
)
case_docker_arch_suffix_removal() ( local base sim out; new_case_env dockerarch >/dev/null; base="$CASE_BASE"; source_module_defs docker; sim="$base/sim"; printf 'Remv docker.io:amd64 [1]\nRemv nginx:amd64 [1]\n' > "$sim"; out="$(_unexpected_removals "$sim")"; [[ "$out" == nginx ]]; )
case_authorized_keys_options_and_modes() (
  local base home
  new_case_env keyoptions >/dev/null; base="$CASE_BASE"; source_module_defs ssh
  home="$base/home"; mkdir -p "$home/.ssh"; chmod 755 "$home"; chmod 700 "$home/.ssh"
  printf 'from="10.0.0.1",no-agent-forwarding ssh-ed25519 AAAATEST comment\n' > "$home/.ssh/authorized_keys"; chmod 600 "$home/.ssh/authorized_keys"
  make_mock "$base" getent <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == passwd && "$2" == testadmin ]] && { printf 'testadmin:x:0:0::%s/home:/bin/bash\n' "$CASE_BASE"; exit 0; }
exit 2
MOCK
  SUDO_USER=testadmin has_admin_key || return 1
  chmod 666 "$home/.ssh/authorized_keys"
  ! SUDO_USER=testadmin has_admin_key
)

case_firewall_proto_validation() ( new_case_env fwproto >/dev/null; source_module_defs firewall; require_root(){ return 0; }; deny_rule 12345 sctp >/dev/null 2>&1; [[ $? -eq 64 ]]; )

case_ssh_foreign_managed_path_rejected() (
  local base rc=0
  new_case_env sshforeign >/dev/null; base="$CASE_BASE"
  export VPSG_SSH_CONF="$base/ssh/00-vps-guard.conf" VPSG_SSH_LEGACY_CONF="$base/ssh/90-vps-guard.conf"
  mkdir -p "$base/ssh"; printf 'PasswordAuthentication yes
' > "$VPSG_SSH_CONF"
  source_module_defs ssh; require_root(){ return 0; }
  prepare >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 30 && "$(cat "$VPSG_SSH_CONF")" == 'PasswordAuthentication yes' ]]
)
case_ssh_managed_legacy_allowed() (
  local base
  new_case_env sshlegacy >/dev/null; base="$CASE_BASE"
  export VPSG_SSH_CONF="$base/ssh/00-vps-guard.conf" VPSG_SSH_LEGACY_CONF="$base/ssh/90-vps-guard.conf"
  mkdir -p "$base/ssh"; printf '# Managed by VPS Guard
PubkeyAuthentication yes
' > "$VPSG_SSH_LEGACY_CONF"
  source_module_defs ssh; require_root(){ return 0; }
  prepare >/dev/null
)
case_ssh_port_verification_phases() (
  local base
  new_case_env sshphase >/dev/null; base="$CASE_BASE"
  export VPSG_SSH_CONF="$base/ssh/00-vps-guard.conf" VPSG_SSH_LEGACY_CONF="$base/ssh/90-vps-guard.conf"
  mkdir -p "$base/ssh"; cat > "$VPSG_SSH_CONF" <<'CFG'
PubkeyAuthentication yes
Port 2222
CFG
  make_mock "$base" sshd <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == -t ]]; then exit 0; fi
if [[ "${1:-}" == -T ]]; then printf 'pubkeyauthentication yes\nport 2222\n'; exit 0; fi
exit 0
MOCK
  make_mock "$base" ss <<'MOCK'
#!/usr/bin/env bash
printf 'LISTEN 0 128 0.0.0.0:22 0.0.0.0:*\n'
MOCK
  source_module_defs ssh
  verify_config >/dev/null 2>&1 || return 1
  verify_runtime >/dev/null 2>&1 && return 1
  return 0
)
case_watch_threshold() ( new_case_env watchthr >/dev/null; source_module_defs watch; [[ "$(_sev_rank CRITICAL)" -gt "$(_sev_rank HIGH)" && "$(_sev_rank HIGH)" -gt "$(_sev_rank MEDIUM)" ]]; )
case_watch_report_severity() ( local base f; new_case_env watchsev >/dev/null; base="$CASE_BASE"; source_module_defs watch; f="$base/r"; printf 'header\n6379 tcp CRITICAL wildcard\n[HIGH] key changed\n' > "$f"; [[ "$(_report_max_severity "$f")" == CRITICAL ]]; )
case_watch_fingerprint_stable() ( local base a b; new_case_env watchfp >/dev/null; base="$CASE_BASE"; source_module_defs watch; a="$base/a"; b="$base/b"; printf 'time one\n[HIGH] same risk\n' > "$a"; printf 'time two\n[HIGH] same risk\n' > "$b"; [[ "$(_report_fingerprint "$a")" == "$(_report_fingerprint "$b")" ]]; )
case_watch_hook_permissions() ( local base; new_case_env watchhook >/dev/null; base="$CASE_BASE"; source_module_defs watch; mkdir -p "$VPSG_ETC_DIR"; printf '#!/bin/sh\nexit 0\n' > "$HOOK"; chmod 777 "$HOOK"; ! _hook_safe; )
case_incident_privacy_default() ( new_case_env incident >/dev/null; local text; text="$(cat "$ROOT/modules/builtin/incident/module.sh")"; assert_contains "$text" 'ps -eo user,pid,ppid,stat,lstart,comm' && assert_contains "$text" '--include-command-lines'; )
case_system_simulation() ( new_case_env sysplan >/dev/null; source_module_defs system; type _simulate_upgrade >/dev/null && [[ "$(type -t _simulate_upgrade)" == function ]]; )
case_setup_guide() ( new_case_env setup >/dev/null; local out; out="$(bash "$ROOT/bin/vpsg" setup guide)"; assert_contains "$out" 'Safe Change' && assert_contains "$out" 'Baseline'; )
case_baseline_list() ( new_case_env baseline >/dev/null; local out; out="$(bash "$ROOT/bin/vpsg" baseline list)"; assert_contains "$out" '暂无安全基线'; )
case_watch_status() ( new_case_env watchstatus >/dev/null; local out; out="$(bash "$ROOT/bin/vpsg" watch status)"; assert_contains "$out" 'VPS Guard Watch'; )
case_panel_status() ( new_case_env panelstatus >/dev/null; local out; out="$(bash "$ROOT/bin/vpsg" panel status)"; assert_contains "$out" '1Panel'; )
case_symlink_entry() ( local base link; new_case_env symlinkentry >/dev/null; base="$CASE_BASE"; link="$base/vpsg"; ln -s "$ROOT/bin/vpsg" "$link"; [[ "$(bash "$link" --version)" == 0.4.0 ]]; )


case_watch_foreign_unit_refused() (
  local base rc=0 original
  new_case_env watchforeign >/dev/null; base="$CASE_BASE"; source_module_defs watch
  mkdir -p "$VPSG_SYSTEMD_DIR"; printf '[Unit]\nDescription=Foreign unit\n' > "$SERVICE"; original="$(cat "$SERVICE")"
  require_root(){ return 0; }
  make_mock "$base" systemctl <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  disable_watch >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 30 && -f "$SERVICE" && "$(cat "$SERVICE")" == "$original" ]]
)

case_swap_state_binds_created_resource() (
  local base managed victim identity unit file
  new_case_env swapbind >/dev/null; base="$CASE_BASE"
  export VPSG_SWAPFILE="$base/victim.swap"; source_module_defs swap
  managed="$base/managed.swap"; victim="$VPSG_SWAPFILE"; printf managed > "$managed"; printf victim > "$victim"
  identity="$(_swap_identity "$managed")"; mkdir -p "$VPSG_STATE_DIR" "$VPSG_SYSTEMD_DIR"
  cat > "$STATE" <<EOF_STATE
schema=2
swapfile=$managed
file_identity=$identity
size_mb=256
EOF_STATE
  unit="$(unit_name_for "$managed")"; file="$(unit_file_for "$managed")"
  cat > "$file" <<EOF_UNIT
# Managed by VPS Guard
[Unit]
Description=VPS Guard swap file
[Swap]
What=$managed
EOF_UNIT
  require_root(){ return 0; }
  make_mock "$base" systemctl <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  make_mock "$base" swapoff <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  rollback >/dev/null || return 1
  [[ ! -e "$managed" && -f "$victim" && "$(cat "$victim")" == victim && ! -e "$STATE" ]]
)

case_swap_identity_change_refused() (
  local base target identity rc=0
  new_case_env swapidentity >/dev/null; base="$CASE_BASE"
  export VPSG_SWAPFILE="$base/unused.swap"; source_module_defs swap
  target="$base/managed.swap"; printf first > "$target"; identity="$(_swap_identity "$target")"
  mkdir -p "$VPSG_STATE_DIR"; cat > "$STATE" <<EOF_STATE
schema=2
swapfile=$target
file_identity=$identity
size_mb=256
EOF_STATE
  rm -f "$target"; printf replacement > "$target"
  require_root(){ return 0; }
  rollback >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 30 && -f "$target" && "$(cat "$target")" == replacement && -f "$STATE" ]]
)

run_test 'users list human-readable state' case_users_list
run_test 'users password disable requires SSH key' case_users_password_disable_requires_key
run_test 'users password disable preserves public-key account path' case_users_password_disable_preserves_pubkey_path
run_test '1Panel checked-install plan' case_panel_plan
run_test '1Panel upstream installer gets sanitized environment' case_panel_sanitized_environment
run_test 'network target option-injection guard' case_network_route_injection
run_test 'third-party integrations HTTPS only' case_network_external_https
run_test 'third-party root execution downgrades read-only' case_network_root_downgrade_readable
run_test 'Docker repository symlink rejection' case_docker_repo_symlink_rejected
run_test 'Docker apt architecture suffix parsing' case_docker_arch_suffix_removal
run_test 'authorized_keys options and StrictModes sanity' case_authorized_keys_options_and_modes
run_test 'firewall protocol validation' case_firewall_proto_validation
run_test 'SSH foreign managed path rejection' case_ssh_foreign_managed_path_rejected
run_test 'SSH legacy managed file accepted' case_ssh_managed_legacy_allowed
run_test 'SSH port migration separates config/runtime verification' case_ssh_port_verification_phases
run_test 'Watch severity ranking' case_watch_threshold
run_test 'Watch report max severity' case_watch_report_severity
run_test 'Watch notification fingerprint stability' case_watch_fingerprint_stable
run_test 'Watch unsafe hook rejection' case_watch_hook_permissions
run_test 'Watch refuses foreign systemd units' case_watch_foreign_unit_refused
run_test 'Incident command-line privacy default' case_incident_privacy_default
run_test 'system upgrade simulation helper' case_system_simulation
run_test 'beginner setup guide' case_setup_guide
run_test 'baseline empty list' case_baseline_list
run_test 'watch status' case_watch_status
run_test 'panel status' case_panel_status
run_test 'Swap rollback binds recorded resource' case_swap_state_binds_created_resource
run_test 'Swap rollback refuses replaced file' case_swap_identity_change_refused
run_test 'symlink entrypoint' case_symlink_entry
