#!/usr/bin/env bash
set -uo pipefail
VPSG_ROOT="${VPSG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
. "$VPSG_ROOT/core/common.sh"
. "$VPSG_ROOT/core/platform.sh"
CONF="/etc/fail2ban/jail.d/90-vps-guard.local"
LAST="$VPSG_STATE_DIR/fail2ban-last-backup"

status() {
  if ! have fail2ban-client; then [[ "${1:-}" == "--brief" ]] && echo "未安装" || echo "Fail2Ban: 未安装"; return 0; fi
  if systemctl is-active --quiet fail2ban 2>/dev/null; then
    [[ "${1:-}" == "--brief" ]] && echo "运行中" || fail2ban-client status sshd 2>/dev/null || fail2ban-client status
  else
    [[ "${1:-}" == "--brief" ]] && echo "未运行" || echo "Fail2Ban: 未运行"
  fi
}

plan() {
  local p; p="$(ssh_primary_port 2>/dev/null)" || { error "无法确认 SSH 端口"; return 30; }
  cat <<PLAN
计划安装并配置 Fail2Ban SSH jail，监听 SSH 端口 $p：
  maxretry = 5
  findtime = 10m
  bantime = 1h
仅写入 $CONF，不覆盖 jail.local。
PLAN
}

apply() {
  require_root || return 1
  local p; p="$(ssh_primary_port 2>/dev/null)" || { error "无法确认 SSH 端口"; return 30; }
  plan || return $?
  confirm "应用 Fail2Ban 配置？" || return 10
  have fail2ban-client || apt_install fail2ban || return 40
  ensure_runtime_dirs
  mkdir -p /etc/fail2ban/jail.d
  local backup; backup="$(managed_backup "$CONF" fail2ban)"; printf '%s\n' "$backup" > "$LAST"
  cat > "$CONF" <<CFG
# Managed by VPS Guard
[sshd]
enabled = true
port = $p
maxretry = 5
findtime = 10m
bantime = 1h
CFG
  if ! fail2ban-client -t >/dev/null 2>&1; then
    error "Fail2Ban 配置检查失败，正在恢复"
    rollback >/dev/null 2>&1 || true
    return 30
  fi
  systemctl enable --now fail2ban >/dev/null 2>&1 || return 40
  systemctl restart fail2ban || return 40
  sleep 1
  verify || return 50
  log_event INFO "fail2ban applied ssh_port=$p"
}

verify() {
  systemctl is-active --quiet fail2ban 2>/dev/null || return 1
  fail2ban-client status sshd >/dev/null 2>&1 || return 1
  ok "Fail2Ban sshd jail 运行正常"
}

rollback() {
  require_root || return 1
  [[ -r "$LAST" ]] || { error "没有 Fail2Ban 回滚点"; return 20; }
  local backup; backup="$(cat "$LAST")"
  if [[ -e "$backup" ]]; then cp -a "$backup" "$CONF"; elif [[ -e "$backup.absent" ]]; then rm -f "$CONF"; else return 60; fi
  have fail2ban-client && fail2ban-client -t >/dev/null 2>&1 || true
  systemctl restart fail2ban 2>/dev/null || true
  ok "Fail2Ban 上次修改已回滚"
}

action="${1:-status}"; shift || true
parse_yes_flag "$@"
case "$action" in
  status|check) status "$@" ;;
  plan) plan ;;
  apply) apply ;;
  verify) verify ;;
  rollback) rollback ;;
  doctor) plan >/dev/null && ok "Fail2Ban 前置检查通过" || exit 30 ;;
  *) error "fail2ban 支持: status|plan|apply|verify|rollback|doctor"; exit 64 ;;
esac
