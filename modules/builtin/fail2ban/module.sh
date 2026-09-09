#!/usr/bin/env bash
set -uo pipefail
VPSG_ROOT="${VPSG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
. "$VPSG_ROOT/core/common.sh"
CONF="$VPSG_FAIL2BAN_JAIL_DIR/90-vps-guard.local"
STATE="$VPSG_STATE_DIR/fail2ban-last.state"
LAST="$VPSG_STATE_DIR/fail2ban-last-backup"

status() {
  if ! have fail2ban-client; then [[ "${1:-}" == --brief ]] && echo "未安装" || echo "Fail2Ban: 未安装"; return 0; fi
  local s=stopped; have systemctl && systemctl is-active --quiet fail2ban 2>/dev/null && s=running
  [[ "${1:-}" == --brief ]] && { echo "$s"; return; }
  echo "Fail2Ban: $s"; fail2ban-client status 2>/dev/null || true
}
plan() { cat <<'EOF_PLAN'
计划：安装 Fail2Ban，并只管理 /etc/fail2ban/jail.d/90-vps-guard.local。
启用 sshd jail；不会覆盖管理员其它 jail 配置。修改前记录服务 active/enabled 状态，失败可恢复。
EOF_PLAN
}

apply() {
  require_root || return 1; plan; confirm "安装/配置 Fail2Ban？" || return 10
  ensure_runtime_dirs || return 40
  local was_installed=0 was_active=0 was_enabled=0 backup
  have fail2ban-client && was_installed=1
  have systemctl && systemctl is-active --quiet fail2ban 2>/dev/null && was_active=1
  have systemctl && systemctl is-enabled --quiet fail2ban 2>/dev/null && was_enabled=1
  backup="$(managed_backup "$CONF" fail2ban)" || return 40
  printf '%s\n' "$backup" | atomic_write_file "$LAST" 600 || return 40
  cat <<EOF_STATE | atomic_write_file "$STATE" 600 || return 40
was_installed=$was_installed
was_active=$was_active
was_enabled=$was_enabled
EOF_STATE
  have fail2ban-client || apt_install fail2ban || return 40
  cat <<'EOF_CONF' | atomic_write_file "$CONF" 644 || { rollback >/dev/null 2>&1 || true; return 40; }
# Managed by VPS Guard
[sshd]
enabled = true
backend = systemd
bantime = 1h
findtime = 10m
maxretry = 5
EOF_CONF
  if ! fail2ban-client -t >/dev/null 2>&1; then error "Fail2Ban 配置验证失败，正在恢复"; rollback >/dev/null 2>&1 || true; return 50; fi
  if have systemctl; then systemctl enable --now fail2ban >/dev/null 2>&1 || { rollback >/dev/null 2>&1 || true; return 40; }; systemctl restart fail2ban || { rollback >/dev/null 2>&1 || true; return 40; }; fi
  verify || { rollback >/dev/null 2>&1 || true; return 50; }
  log_event INFO "fail2ban applied"; ok "Fail2Ban sshd jail 已启用"
}
verify() { have fail2ban-client || return 1; fail2ban-client -t >/dev/null 2>&1 || return 1; have systemctl && systemctl is-active --quiet fail2ban 2>/dev/null || return 1; fail2ban-client status sshd >/dev/null 2>&1 || return 1; ok "Fail2Ban 验证通过"; }

rollback() {
  require_root || return 1; [[ -r "$LAST" && -r "$STATE" ]] || { error "没有 Fail2Ban 回滚点"; return 20; }
  local b was_active was_enabled; b="$(cat "$LAST")"; [[ "$b" == "$VPSG_BACKUP_DIR"/fail2ban/* ]] || { error "Fail2Ban 回滚路径不可信"; return 70; }
  was_active="$(awk -F= '$1=="was_active" {print $2}' "$STATE")"; was_enabled="$(awk -F= '$1=="was_enabled" {print $2}' "$STATE")"
  if [[ -f "$b" ]]; then atomic_copy_file "$b" "$CONF" "$(stat -c '%a' "$b" 2>/dev/null || echo 644)" || return 40
  elif [[ -e "$b.absent" ]]; then rm -f -- "$CONF"
  else error "Fail2Ban 备份不存在"; return 20; fi
  if have fail2ban-client && ! fail2ban-client -t >/dev/null 2>&1; then error "恢复后的 Fail2Ban 配置验证失败"; return 50; fi
  if have systemctl; then
    if [[ "$was_enabled" == 1 ]]; then systemctl enable fail2ban >/dev/null 2>&1 || true; else systemctl disable fail2ban >/dev/null 2>&1 || true; fi
    if [[ "$was_active" == 1 ]]; then systemctl restart fail2ban >/dev/null 2>&1 || return 50; else systemctl stop fail2ban >/dev/null 2>&1 || true; fi
  fi
  ok "Fail2Ban 配置与服务生命周期已恢复"
}

banned() { have fail2ban-client || return 20; fail2ban-client status sshd; }
unban() { require_root || return 1; local ip="${1:-}"; [[ "$ip" =~ ^[0-9A-Fa-f:.]+$ ]] || { error "用法: sudo vpsg fail2ban unban <IP>"; return 64; }; fail2ban-client set sshd unbanip "$ip"; log_event INFO "fail2ban unban ip=$ip"; }
logs() { journalctl -u fail2ban -n "${1:-100}" --no-pager 2>/dev/null || tail -n "${1:-100}" /var/log/fail2ban.log 2>/dev/null || true; }

action="${1:-status}"; shift || true; parse_yes_flag "$@"
case "$action" in status|check) status "$@";; plan) plan;; apply) apply;; verify) verify;; rollback) rollback;; banned) banned;; unban) unban "$@";; logs) logs "$@";; *) error "fail2ban 支持: status|plan|apply|verify|rollback|banned|unban|logs"; exit 64;; esac
