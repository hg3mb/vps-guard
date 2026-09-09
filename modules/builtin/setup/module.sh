#!/usr/bin/env bash
set -uo pipefail
VPSG_ROOT="${VPSG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
. "$VPSG_ROOT/core/common.sh"
. "$VPSG_ROOT/core/platform.sh"

guide() {
  platform_detect || true
  local baseline=no watch=no f2b=no ufw=no sshkeys=0 profile
  [[ -d "$VPSG_STATE_DIR/baselines/default" ]] && baseline=yes
  have systemctl && systemctl is-enabled --quiet vps-guard-watch.timer 2>/dev/null && watch=yes
  have systemctl && systemctl is-active --quiet fail2ban 2>/dev/null && f2b=yes
  have ufw && ufw status 2>/dev/null | grep -q '^Status: active' && ufw=yes
  profile="$(cat "$VPSG_ETC_DIR/profile" 2>/dev/null || echo general)"
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then
    sshkeys="$(/bin/bash "$VPSG_ROOT/modules/builtin/users/module.sh" list 2>/dev/null | awk -v u="$SUDO_USER" '$1==u {print $5; exit}')"
  fi
  [[ "$sshkeys" =~ ^[0-9]+$ ]] || sshkeys=0

  printf '%s\n' \
    'VPS Guard 新手安全向导' \
    '=====================' \
    "系统: ${VPSG_OS_PRETTY:-unknown}" \
    "服务器用途: $profile" \
    "UFW: $ufw   Fail2Ban: $f2b   Baseline: $baseline   Watch: $watch" \
    '' \
    '推荐顺序（不会自动一次性修改整台服务器）：' \
    '  1. 先看: vpsg doctor / sudo vpsg exposure scan' \
    '  2. 设置用途: sudo vpsg exposure profile set web|docker-web|database|proxy|general' \
    '  3. 准备第二个管理员账号: sudo vpsg users bootstrap <linux-user> <github-user>' \
    '  4. 配置 Fail2Ban: sudo vpsg fail2ban apply' \
    '  5. 启用自动安全更新: sudo vpsg system auto-enable' \
    '  6. 用 Safe Change 加固 SSH: sudo vpsg ssh apply' \
    '  7. 用 Safe Change 启用 UFW: sudo vpsg firewall apply' \
    '  8. 确认当前状态可信后创建基线: sudo vpsg baseline create' \
    '  9. 启用每天检查: sudo vpsg watch enable' \
    '' \
    '原则：SSH/UFW 这类可能让你失联的变更必须保留当前会话，并用新 SSH 窗口验证后再 commit。'
}

checklist() {
  echo '=== VPS Guard readiness ==='
  /bin/bash "$VPSG_ROOT/bin/vpsg" doctor || true
  echo
  guide
}

action="${1:-guide}"
shift || true
case "$action" in
  guide|status) guide ;;
  check|checklist) checklist ;;
  *) error 'setup 支持: guide|checklist'; exit 64 ;;
esac
