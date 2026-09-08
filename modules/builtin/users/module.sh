#!/usr/bin/env bash
set -uo pipefail
VPSG_ROOT="${VPSG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
. "$VPSG_ROOT/core/common.sh"

valid_user() { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
is_sudo_user() { id -nG "$1" 2>/dev/null | tr ' ' '\n' | grep -Eq '^(sudo|wheel|admin)$'; }

list_users() {
  printf '%-18s %-7s %-7s %-10s %s\n' USER UID LOCKED SUDO SHELL
  while IFS=: read -r u _ uid _ _ _ shell; do
    (( uid == 0 || uid >= 1000 )) || continue; [[ "$shell" =~ (nologin|false)$ ]] && continue
    local locked=no sudo=no; passwd -S "$u" 2>/dev/null | awk '{print $2}' | grep -q '^L' && locked=yes; is_sudo_user "$u" && sudo=yes
    printf '%-18s %-7s %-7s %-10s %s\n' "$u" "$uid" "$locked" "$sudo" "$shell"
  done < <(getent passwd)
}

add_user() {
  require_root || return 1
  local u="${1:-}" sudo_flag=0; shift || true; valid_user "$u" || { error "用法: sudo vpsg users add <username> [--sudo]"; return 64; }
  while (($#)); do case "$1" in --sudo) sudo_flag=1; shift;; --yes|-y) VPSG_ASSUME_YES=1; shift;; *) error "未知参数: $1"; return 64;; esac; done
  getent passwd "$u" >/dev/null && { error "用户已存在: $u"; return 30; }
  echo "将创建普通用户 $u（默认不设置密码，建议导入 SSH key）。"; (( sudo_flag )) && echo "并授予 sudo 权限。"
  confirm "继续创建？" || return 10
  useradd -m -s /bin/bash "$u" || return 40; passwd -l "$u" >/dev/null 2>&1 || true
  if (( sudo_flag )); then have sudo || apt-get install -y sudo >/dev/null; usermod -aG sudo "$u" || return 40; fi
  log_event INFO "user created user=$u sudo=$sudo_flag"; ok "用户已创建: $u"; echo "导入 GitHub 公钥示例: sudo vpsg ssh import-github <github-user> --user $u"
}

sudo_change() {
  require_root || return 1; local u="${1:-}" mode="${2:-}"; valid_user "$u" && getent passwd "$u" >/dev/null || { error "用户不存在/格式无效"; return 64; }
  case "$mode" in enable) have sudo || apt-get install -y sudo >/dev/null; usermod -aG sudo "$u";; disable) [[ "$u" != "root" ]] || { error "不能移除 root 管理权限"; return 30; }; gpasswd -d "$u" sudo >/dev/null 2>&1 || true;; *) error "用法: users sudo <user> <enable|disable>"; return 64;; esac
  log_event INFO "sudo membership user=$u mode=$mode"; ok "sudo 权限已更新: $u -> $mode"
}

lock_change() { require_root || return 1; local u="${1:-}" mode="${2:-}"; valid_user "$u" && getent passwd "$u" >/dev/null || return 64; [[ "$u" != "root" ]] || { error "拒绝锁定 root"; return 30; }; case "$mode" in lock) usermod -L "$u";; unlock) usermod -U "$u";; *) return 64;; esac; ok "$u: $mode"; }

remove_user() {
  require_root || return 1; local u="${1:-}" remove_home=0; shift || true; valid_user "$u" || return 64; [[ "$u" != "root" ]] || { error "拒绝删除 root"; return 30; }
  [[ "$u" != "${SUDO_USER:-}" && "$u" != "${USER:-}" ]] || { error "拒绝删除当前管理会话用户"; return 30; }
  getent passwd "$u" >/dev/null || { error "用户不存在: $u"; return 20; }
  while (($#)); do case "$1" in --remove-home) remove_home=1; shift;; --yes|-y) VPSG_ASSUME_YES=1; shift;; *) shift;; esac; done
  echo "将删除用户 $u。"; (( remove_home )) && echo "同时删除其 home 目录。"; confirm "确认删除？" || return 10
  if (( remove_home )); then userdel -r "$u"; else userdel "$u"; fi; log_event INFO "user removed user=$u remove_home=$remove_home"; ok "用户已删除: $u"
}

menu() {
  list_users; echo; echo "1) 创建用户 2) 授予sudo 3) 移除sudo 4) 锁定用户 5) 解锁用户 6) 删除用户 0) 返回"; read -r -p '请选择: ' c
  case "$c" in 1) read -r -p '用户名: ' u; add_user "$u";; 2) read -r -p '用户名: ' u; sudo_change "$u" enable;; 3) read -r -p '用户名: ' u; sudo_change "$u" disable;; 4) read -r -p '用户名: ' u; lock_change "$u" lock;; 5) read -r -p '用户名: ' u; lock_change "$u" unlock;; 6) read -r -p '用户名: ' u; remove_user "$u";; esac
}

action="${1:-list}"; shift || true; parse_yes_flag "$@"
case "$action" in list|status|check) list_users;; add) add_user "$@";; sudo) sudo_change "$@";; lock) lock_change "${1:-}" lock;; unlock) lock_change "${1:-}" unlock;; remove) remove_user "$@";; menu) menu;; *) error "users 支持: list|add|sudo|lock|unlock|remove|menu"; exit 64;; esac
