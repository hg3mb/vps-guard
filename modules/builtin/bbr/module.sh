#!/usr/bin/env bash
set -uo pipefail
VPSG_ROOT="${VPSG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
. "$VPSG_ROOT/core/common.sh"
CONF="$VPSG_SYSCTL_DIR/90-vps-guard-bbr.conf"
STATE="$VPSG_STATE_DIR/bbr-last.state"
LAST="$VPSG_STATE_DIR/bbr-last-backup"
status() { local cc q; cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"; q="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"; [[ "${1:-}" == --brief ]] && echo "$cc" || { echo "拥塞控制: $cc"; echo "队列算法: $q"; }; }
plan() { cat <<'EOF_PLAN'
计划启用 Linux BBR：
  net.core.default_qdisc=fq
  net.ipv4.tcp_congestion_control=bbr
仅在当前内核明确提供 BBR 时继续；使用独立 sysctl.d 文件，不改 /etc/sysctl.conf。
EOF_PLAN
}
apply() {
  require_root || return 1; plan; confirm "启用 BBR？" || return 10
  modprobe tcp_bbr 2>/dev/null || true
  sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | tr ' ' '\n' | grep -qx bbr || { error "当前内核不提供 BBR"; return 20; }
  ensure_runtime_dirs || return 40
  local old_cc old_q backup; old_cc="$(sysctl -n net.ipv4.tcp_congestion_control)"; old_q="$(sysctl -n net.core.default_qdisc)"; backup="$(managed_backup "$CONF" bbr)" || return 40
  printf '%s\n' "$backup" | atomic_write_file "$LAST" 600 || return 40
  printf 'old_cc=%s\nold_q=%s\n' "$old_cc" "$old_q" | atomic_write_file "$STATE" 600 || return 40
  cat <<'EOF_CONF' | atomic_write_file "$CONF" 644 || return 40
# Managed by VPS Guard
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF_CONF
  if ! sysctl -w net.core.default_qdisc=fq >/dev/null || ! sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null || ! verify; then error "BBR 应用失败，正在恢复"; rollback >/dev/null 2>&1 || true; return 50; fi
  log_event INFO "bbr applied"
}
verify() { [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == bbr && "$(sysctl -n net.core.default_qdisc 2>/dev/null)" == fq ]] || return 1; ok "BBR 已生效"; }
rollback() {
  require_root || return 1; [[ -r "$LAST" && -r "$STATE" ]] || { error "没有 BBR 回滚点"; return 20; }
  local b old_cc old_q; b="$(cat "$LAST")"; [[ "$b" == "$VPSG_BACKUP_DIR"/bbr/* ]] || { error "BBR 回滚路径不可信"; return 70; }
  old_cc="$(awk -F= '$1=="old_cc" {print $2}' "$STATE")"; old_q="$(awk -F= '$1=="old_q" {print $2}' "$STATE")"
  if [[ -f "$b" ]]; then atomic_copy_file "$b" "$CONF" "$(stat -c '%a' "$b" 2>/dev/null || echo 644)" || return 40
  elif [[ -e "$b.absent" ]]; then rm -f -- "$CONF"
  else error "BBR 备份不存在"; return 20; fi
  [[ -n "$old_q" ]] && sysctl -w "net.core.default_qdisc=$old_q" >/dev/null 2>&1 || true
  [[ -n "$old_cc" ]] && sysctl -w "net.ipv4.tcp_congestion_control=$old_cc" >/dev/null 2>&1 || true
  [[ -n "$old_cc" && "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "$old_cc" ]] || warn "拥塞控制无法恢复到原值 $old_cc"
  ok "BBR 上次修改已回滚"
}
action="${1:-status}"; shift || true; parse_yes_flag "$@"
case "$action" in status|check) status "$@";; plan) plan;; apply) apply;; verify) verify;; rollback) rollback;; *) error "bbr 支持: status|plan|apply|verify|rollback"; exit 64;; esac
