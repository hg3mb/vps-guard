#!/usr/bin/env bash
set -uo pipefail
VPSG_ROOT="${VPSG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
. "$VPSG_ROOT/core/common.sh"
CONF="/etc/sysctl.d/90-vps-guard-bbr.conf"
STATE="$VPSG_STATE_DIR/bbr-last.state"
LAST="$VPSG_STATE_DIR/bbr-last-backup"

status() {
  local cc q
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
  q="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
  if [[ "${1:-}" == "--brief" ]]; then echo "$cc"; else echo "拥塞控制: $cc"; echo "队列算法: $q"; fi
}

plan() {
  cat <<'PLAN'
计划启用 Linux BBR：
  net.core.default_qdisc=fq
  net.ipv4.tcp_congestion_control=bbr
仅在内核提供 BBR 时继续，并写入独立 sysctl.d 配置片段。
PLAN
}

apply() {
  require_root || return 1
  plan
  confirm "启用 BBR？" || return 10
  modprobe tcp_bbr 2>/dev/null || true
  sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | tr ' ' '\n' | grep -qx bbr || { error "当前内核不提供 BBR"; return 20; }
  ensure_runtime_dirs
  local old_cc old_q backup
  old_cc="$(sysctl -n net.ipv4.tcp_congestion_control)"; old_q="$(sysctl -n net.core.default_qdisc)"
  backup="$(managed_backup "$CONF" bbr)"; printf '%s\n' "$backup" > "$LAST"
  printf 'old_cc=%s\nold_q=%s\n' "$old_cc" "$old_q" > "$STATE"
  cat > "$CONF" <<'CFG'
# Managed by VPS Guard
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
CFG
  sysctl -w net.core.default_qdisc=fq >/dev/null || return 40
  sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null || return 40
  verify || return 50
  log_event INFO "bbr applied"
}

verify() {
  [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]] || return 1
  [[ "$(sysctl -n net.core.default_qdisc 2>/dev/null)" == "fq" ]] || return 1
  ok "BBR 已生效"
}

rollback() {
  require_root || return 1
  [[ -r "$LAST" && -r "$STATE" ]] || { error "没有 BBR 回滚点"; return 20; }
  local backup old_cc old_q
  backup="$(cat "$LAST")"
  old_cc="$(awk -F= '$1=="old_cc" {print $2}' "$STATE")"; old_q="$(awk -F= '$1=="old_q" {print $2}' "$STATE")"
  if [[ -e "$backup" ]]; then cp -a "$backup" "$CONF"; elif [[ -e "$backup.absent" ]]; then rm -f "$CONF"; fi
  [[ -n "$old_q" ]] && sysctl -w "net.core.default_qdisc=$old_q" >/dev/null 2>&1 || true
  [[ -n "$old_cc" ]] && sysctl -w "net.ipv4.tcp_congestion_control=$old_cc" >/dev/null 2>&1 || true
  ok "BBR 上次修改已回滚"
}

action="${1:-status}"; shift || true
parse_yes_flag "$@"
case "$action" in
  status|check) status "$@" ;;
  plan) plan ;;
  apply) apply ;;
  verify) verify ;;
  rollback) rollback ;;
  *) error "bbr 支持: status|plan|apply|verify|rollback"; exit 64 ;;
esac
