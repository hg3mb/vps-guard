#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/testlib.sh"

_install_env() {
  local base="$1"
  export VPSG_INSTALL_ALLOW_NONROOT=1
  export VPSG_INSTALL_DEST="$base/lib/vps-guard"
  export VPSG_INSTALL_LINK="$base/bin/vpsg"
  export VPSG_INSTALL_STATE_DIR="$base/state-install"
  export VPSG_INSTALL_ETC_DIR="$base/etc-install"
  export VPSG_INSTALL_LOG_DIR="$base/log-install"
}
case_install_smoke() ( local base out; new_case_env install >/dev/null; base="$CASE_BASE"; _install_env "$base"; bash "$ROOT/install.sh" >/dev/null || return 1; [[ -L "$VPSG_INSTALL_LINK" && -f "$VPSG_INSTALL_DEST/bin/vpsg" ]] || return 1; out="$(bash "$VPSG_INSTALL_LINK" --version)"; [[ "$out" == 0.4.0 ]]; )
case_install_upgrade_rollback() ( local base backup; new_case_env upgrade >/dev/null; base="$CASE_BASE"; _install_env "$base"; bash "$ROOT/install.sh" >/dev/null || return 1; printf '# marker-old\n' >> "$VPSG_INSTALL_DEST/README.md"; bash "$ROOT/install.sh" >/dev/null || return 1; backup="$(find "$VPSG_INSTALL_STATE_DIR/install-backups" -type d -name previous | sort -r | head -1)"; [[ -n "$backup" ]] || return 1; grep -q '# marker-old' "$backup/README.md" || return 1; bash "$ROOT/install.sh" --rollback "$backup" >/dev/null || return 1; grep -q '# marker-old' "$VPSG_INSTALL_DEST/README.md"; )
case_install_foreign_link_rejected() ( local base rc=0; new_case_env foreignlink >/dev/null; base="$CASE_BASE"; _install_env "$base"; mkdir -p "$(dirname "$VPSG_INSTALL_LINK")"; ln -s /bin/true "$VPSG_INSTALL_LINK"; bash "$ROOT/install.sh" >/dev/null 2>&1 || rc=$?; [[ $rc -eq 70 && "$(readlink "$VPSG_INSTALL_LINK")" == /bin/true ]]; )
case_install_regular_link_path_rejected() ( local base rc=0; new_case_env regularlink >/dev/null; base="$CASE_BASE"; _install_env "$base"; mkdir -p "$(dirname "$VPSG_INSTALL_LINK")"; printf keep > "$VPSG_INSTALL_LINK"; bash "$ROOT/install.sh" >/dev/null 2>&1 || rc=$?; [[ $rc -eq 70 && "$(cat "$VPSG_INSTALL_LINK")" == keep ]]; )
case_install_dangerous_dest() ( local base rc=0; new_case_env dangerdest >/dev/null; base="$CASE_BASE"; _install_env "$base"; export VPSG_INSTALL_DEST='/var/lib/..'; bash "$ROOT/install.sh" >/dev/null 2>&1 || rc=$?; [[ $rc -eq 70 ]]; )
case_install_link_parent_failure_restores_old() (
  local base rc=0
  new_case_env installrestore >/dev/null; base="$CASE_BASE"; _install_env "$base"
  bash "$ROOT/install.sh" >/dev/null || return 1
  printf '# preserve-me\n' >> "$VPSG_INSTALL_DEST/README.md"
  rm -f -- "$VPSG_INSTALL_LINK"; rmdir "$(dirname "$VPSG_INSTALL_LINK")" || return 1; printf blocker > "$(dirname "$VPSG_INSTALL_LINK")"
  bash "$ROOT/install.sh" >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 40 && -d "$VPSG_INSTALL_DEST" ]] || return 1
  grep -q '# preserve-me' "$VPSG_INSTALL_DEST/README.md"
)

case_install_symlink_ancestor_rejected() (
  local base rc=0
  new_case_env installancestor >/dev/null; base="$CASE_BASE"; _install_env "$base"
  mkdir -p "$base/real-parent" "$base/link-root"
  ln -s "$base/real-parent" "$base/link-root/redirect"
  export VPSG_INSTALL_DEST="$base/link-root/redirect/vps-guard"
  bash "$ROOT/install.sh" >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 70 && ! -e "$base/real-parent/vps-guard" ]]
)
case_install_symlink_runtime_subdir_rejected() (
  local base rc=0
  new_case_env installsymlinkruntime >/dev/null; base="$CASE_BASE"; _install_env "$base"
  mkdir -p "$VPSG_INSTALL_STATE_DIR" "$base/outside"
  ln -s "$base/outside" "$VPSG_INSTALL_STATE_DIR/install-backups"
  bash "$ROOT/install.sh" >/dev/null 2>&1 || rc=$?
  [[ $rc -ne 0 && ! -e "$VPSG_INSTALL_DEST" ]]
)

case_install_rollback_symlink_stamp_rejected() (
  local base stamp backup rc=0
  new_case_env rollbacksymlinkstamp >/dev/null; base="$CASE_BASE"; _install_env "$base"
  mkdir -p "$VPSG_INSTALL_STATE_DIR/install-backups" "$base/outside/previous/bin" "$(dirname "$VPSG_INSTALL_DEST")"
  cp "$ROOT/bin/vpsg" "$base/outside/previous/bin/vpsg"
  stamp='20260909-120006-129'; ln -s "$base/outside" "$VPSG_INSTALL_STATE_DIR/install-backups/$stamp"
  backup="$VPSG_INSTALL_STATE_DIR/install-backups/$stamp/previous"
  bash "$ROOT/install.sh" --rollback "$backup" >/dev/null 2>&1 || rc=$?
  [[ $rc -ne 0 ]]
)

case_install_rollback_outside_namespace_rejected() (
  local base other rc=0
  new_case_env rollbacknamespace >/dev/null; base="$CASE_BASE"; _install_env "$base"; mkdir -p "$(dirname "$VPSG_INSTALL_DEST")"
  other="$base/other"; mkdir -p "$other/bin"; cp "$ROOT/bin/vpsg" "$other/bin/vpsg"
  bash "$ROOT/install.sh" --rollback "$other" >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 70 ]]
)
case_uninstall_pending_blocked() ( local base id state rc=0; new_case_env uninstallpending >/dev/null; base="$CASE_BASE"; _install_env "$base"; mkdir -p "$VPSG_INSTALL_DEST" "$VPSG_INSTALL_STATE_DIR/transactions"; id='20260909-120000-123-1abc'; printf '%s\n' "$id" > "$VPSG_INSTALL_STATE_DIR/transactions/current"; state="$VPSG_INSTALL_STATE_DIR/transactions/$id/state"; mkdir -p "$(dirname "$state")"; printf 'status=pending\n' > "$state"; bash "$ROOT/uninstall.sh" >/dev/null 2>&1 || rc=$?; [[ $rc -eq 30 && -d "$VPSG_INSTALL_DEST" ]]; )
case_uninstall_orphan_pending_blocked() (
  local base id state rc=0
  new_case_env uninstallorphan >/dev/null; base="$CASE_BASE"; _install_env "$base"
  mkdir -p "$VPSG_INSTALL_DEST" "$VPSG_INSTALL_STATE_DIR/transactions"
  id='20260909-120001-124-1abd'; state="$VPSG_INSTALL_STATE_DIR/transactions/$id/state"
  mkdir -p "$(dirname "$state")"; printf 'status=pending\n' > "$state"
  # No transactions/current pointer on purpose: this models an orphaned active
  # transaction whose rollback timer may still exist.
  bash "$ROOT/uninstall.sh" >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 30 && -d "$VPSG_INSTALL_DEST" ]]
)

case_uninstall_commit_pending_blocked() (
  local base id state rc=0
  new_case_env uninstallcommitpending >/dev/null; base="$CASE_BASE"; _install_env "$base"
  mkdir -p "$VPSG_INSTALL_DEST" "$VPSG_INSTALL_STATE_DIR/transactions"
  id='20260909-120003-126-1abf'; state="$VPSG_INSTALL_STATE_DIR/transactions/$id/state"
  mkdir -p "$(dirname "$state")"; printf 'status=commit_pending\n' > "$state"
  bash "$ROOT/uninstall.sh" >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 30 && -d "$VPSG_INSTALL_DEST" ]]
)

case_uninstall_prepare_failed_terminal() (
  local base id state
  new_case_env uninstallpreparefailed >/dev/null; base="$CASE_BASE"; _install_env "$base"
  bash "$ROOT/install.sh" >/dev/null || return 1
  id='20260909-120004-127-1ac0'; state="$VPSG_INSTALL_STATE_DIR/transactions/$id/state"
  mkdir -p "$(dirname "$state")"; printf 'status=prepare_failed\n' > "$state"
  bash "$ROOT/uninstall.sh" >/dev/null || return 1
  [[ ! -e "$VPSG_INSTALL_DEST" ]]
)

case_uninstall_symlink_state_blocked() (
  local base id dir rc=0
  new_case_env uninstallsymlinkstate >/dev/null; base="$CASE_BASE"; _install_env "$base"
  mkdir -p "$VPSG_INSTALL_DEST" "$VPSG_INSTALL_STATE_DIR/transactions"
  id='20260909-120005-128-1ac1'; dir="$VPSG_INSTALL_STATE_DIR/transactions/$id"
  mkdir -p "$dir"; printf 'status=committed\n' > "$base/outside-state"; ln -s "$base/outside-state" "$dir/state"
  bash "$ROOT/uninstall.sh" >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 30 && -d "$VPSG_INSTALL_DEST" ]]
)

case_uninstall_unknown_tx_state_blocked() (
  local base id state rc=0
  new_case_env uninstallunknown >/dev/null; base="$CASE_BASE"; _install_env "$base"
  mkdir -p "$VPSG_INSTALL_DEST" "$VPSG_INSTALL_STATE_DIR/transactions"
  id='20260909-120002-125-1abe'; state="$VPSG_INSTALL_STATE_DIR/transactions/$id/state"
  mkdir -p "$(dirname "$state")"; printf 'status=what-is-this\n' > "$state"
  bash "$ROOT/uninstall.sh" >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 30 && -d "$VPSG_INSTALL_DEST" ]]
)

case_uninstall_bad_pointer_blocked() ( local base rc=0; new_case_env uninstallbadptr >/dev/null; base="$CASE_BASE"; _install_env "$base"; mkdir -p "$VPSG_INSTALL_DEST" "$VPSG_INSTALL_STATE_DIR/transactions"; printf '../../etc\n' > "$VPSG_INSTALL_STATE_DIR/transactions/current"; bash "$ROOT/uninstall.sh" >/dev/null 2>&1 || rc=$?; [[ $rc -eq 30 && -d "$VPSG_INSTALL_DEST" ]]; )
case_uninstall_preserves_data() ( local base; new_case_env uninstallkeep >/dev/null; base="$CASE_BASE"; _install_env "$base"; bash "$ROOT/install.sh" >/dev/null || return 1; mkdir -p "$VPSG_INSTALL_STATE_DIR/custom"; printf keep > "$VPSG_INSTALL_STATE_DIR/custom/data"; bash "$ROOT/uninstall.sh" >/dev/null || return 1; [[ ! -e "$VPSG_INSTALL_DEST" && -f "$VPSG_INSTALL_STATE_DIR/custom/data" ]]; )
case_uninstall_purge() ( local base; new_case_env uninstallpurge >/dev/null; base="$CASE_BASE"; _install_env "$base"; bash "$ROOT/install.sh" >/dev/null || return 1; bash "$ROOT/uninstall.sh" --purge-data --yes >/dev/null || return 1; [[ ! -e "$VPSG_INSTALL_DEST" && ! -e "$VPSG_INSTALL_STATE_DIR" && ! -e "$VPSG_INSTALL_ETC_DIR" && ! -e "$VPSG_INSTALL_LOG_DIR" ]]; )

run_test 'installer smoke' case_install_smoke
run_test 'installer upgrade + program rollback' case_install_upgrade_rollback
run_test 'installer refuses foreign symlink' case_install_foreign_link_rejected
run_test 'installer refuses regular link path' case_install_regular_link_path_rejected
run_test 'installer dangerous destination guard' case_install_dangerous_dest
run_test 'installer failure restores previous program' case_install_link_parent_failure_restores_old
run_test 'installer rejects symlink ancestor path' case_install_symlink_ancestor_rejected
run_test 'installer rejects symlinked runtime subdir' case_install_symlink_runtime_subdir_rejected
run_test 'program rollback rejects symlinked backup stamp' case_install_rollback_symlink_stamp_rejected
run_test 'program rollback namespace guard' case_install_rollback_outside_namespace_rejected
run_test 'uninstall blocks pending Safe Change' case_uninstall_pending_blocked
run_test 'uninstall blocks orphaned active Safe Change' case_uninstall_orphan_pending_blocked
run_test 'uninstall blocks commit_pending Safe Change' case_uninstall_commit_pending_blocked
run_test 'uninstall allows prepare_failed terminal transaction' case_uninstall_prepare_failed_terminal
run_test 'uninstall blocks symlinked transaction state' case_uninstall_symlink_state_blocked
run_test 'uninstall blocks unknown Safe Change state' case_uninstall_unknown_tx_state_blocked
run_test 'uninstall blocks malformed transaction pointer' case_uninstall_bad_pointer_blocked
run_test 'uninstall preserves state by default' case_uninstall_preserves_data
run_test 'uninstall purge explicit data removal' case_uninstall_purge
