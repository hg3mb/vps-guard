#!/usr/bin/env bash
set -uo pipefail
VPSG_ROOT="${VPSG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
. "$VPSG_ROOT/core/common.sh"

valid_user() { [[ "${1:-}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
is_sudo_user() { id -nG "$1" 2>/dev/null | tr ' ' '\n' | grep -Fxq sudo; }
_admin_session_user() { [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]] && printf '%s\n' "$SUDO_USER" || true; }
_password_state() { passwd -S "$1" 2>/dev/null | awk '{print $2}' || echo '?'; }
_key_count() {
  local home; home="$(getent passwd "$1" | cut -d: -f6)"; [[ -r "$home/.ssh/authorized_keys" ]] || { echo 0; return; }
  authorized_keys_count_file "$home/.ssh/authorized_keys"
}

list_users() {
  printf '%-18s %-7s %-10s %-11s %-9s %s\n' USER UID PASSWORD SUDO_GROUP SSH_KEYS SHELL
  while IFS=: read -r u _ uid _ _ _ shell; do
    (( uid == 0 || uid >= 1000 )) || continue; [[ "$shell" =~ (nologin|false)$ ]] && continue
    local sudo=no; is_sudo_user "$u" && sudo=yes
    printf '%-18s %-7s %-10s %-11s %-9s %s\n' "$u" "$uid" "$(_password_state "$u")" "$sudo" "$(_key_count "$u")" "$shell"
  done < <(getent passwd)
  echo
  echo "PASSWORD: P=有密码，L=密码字段锁定，NP=无密码。它不等同于 SSH 公钥是否可登录。"
  echo "SUDO_GROUP 仅表示 Debian/Ubuntu sudo 组成员；自定义 /etc/sudoers 授权不在此简表中推断。"
}

_create_account() {
  local u="$1" sudo_flag="${2:-0}"
  useradd -m -s /bin/bash "$u" || return 40
  # Unlock the account while keeping password authentication impossible. A
  # leading '!' can make OpenSSH treat the whole account as locked, including
  # public-key auth on some Linux configurations.
  usermod -p '*NP*' "$u" || { userdel -r "$u" >/dev/null 2>&1 || true; return 40; }
  if ((sudo_flag)); then
    have sudo || DEBIAN_FRONTEND=noninteractive apt-get install -y sudo >/dev/null || { userdel -r "$u" >/dev/null 2>&1 || true; return 40; }
    usermod -aG sudo "$u" || { userdel -r "$u" >/dev/null 2>&1 || true; return 40; }
  fi
}

add_user() {
  require_root || return 1
  local u="${1:-}" sudo_flag=0; shift || true; valid_user "$u" || { error "用法: sudo vpsg users add <username> [--sudo]"; return 64; }
  while (($#)); do case "$1" in --sudo) sudo_flag=1; shift;; --yes|-y) VPSG_ASSUME_YES=1; shift;; *) error "未知参数: $1"; return 64;; esac; done
  getent passwd "$u" >/dev/null && { error "用户已存在: $u"; return 30; }
  echo "将创建 $u；密码字段设为不可用值，默认只建议通过 SSH key 登录。"; ((sudo_flag)) && echo "同时授予 sudo 权限。"
  confirm "继续创建？" || return 10
  _create_account "$u" "$sudo_flag" || return $?
  log_event INFO "user created user=$u sudo=$sudo_flag"; ok "用户已创建: $u"
  echo "下一步建议: sudo vpsg ssh import-github <GitHub用户名> --user $u"
}

sudo_change() {
  require_root || return 1; local u="${1:-}" mode="${2:-}" current
  valid_user "$u" && getent passwd "$u" >/dev/null || { error "用户不存在/格式无效"; return 64; }
  current="$(_admin_session_user)"
  case "$mode" in
    enable) have sudo || DEBIAN_FRONTEND=noninteractive apt-get install -y sudo >/dev/null || return 40; usermod -aG sudo "$u" || return 40 ;;
    disable)
      [[ "$u" != root ]] || { error "不能移除 root 管理权限"; return 30; }
      [[ -z "$current" || "$u" != "$current" ]] || { error "拒绝移除当前 sudo 会话用户 $u 的管理权限；请先用另一个已验证管理员登录。"; return 30; }
      gpasswd -d "$u" sudo >/dev/null 2>&1 || true ;;
    *) error "用法: users sudo <user> <enable|disable>"; return 64 ;;
  esac
  log_event INFO "sudo membership user=$u mode=$mode"; ok "sudo 权限已更新: $u -> $mode"
}

password_disable() {
  require_root || return 1
  local u="${1:-}" keys
  valid_user "$u" && getent passwd "$u" >/dev/null || { error "用户不存在/格式无效"; return 64; }
  [[ "$u" != root ]] || { error "不通过此命令修改 root 密码状态"; return 30; }
  keys="$(_key_count "$u")"
  [[ "$keys" =~ ^[0-9]+$ ]] || keys=0
  if (( keys == 0 )); then
    error "用户 $u 没有检测到 authorized_keys。为避免失去登录方式，拒绝禁用其密码字段。"
    return 30
  fi
  echo "将把 $u 的本地密码字段设置为不可用值 *NP*；不会锁定整个账户，SSH 公钥仍由 sshd 策略决定。"
  confirm "确认禁用 $u 的本地密码？" || return 10
  usermod -p '*NP*' "$u" || return 40
  log_event INFO "local password disabled user=$u"
  ok "$u 的本地密码已禁用；请保留并验证 SSH 公钥登录。"
}

password_set() {
  require_root || return 1
  local u="${1:-}"
  valid_user "$u" && getent passwd "$u" >/dev/null || { error "用户不存在/格式无效"; return 64; }
  [[ "$u" != root ]] || { error "不通过 VPS Guard 用户菜单修改 root 密码；确有需要请直接使用系统 passwd 工具。"; return 30; }
  echo "这只设置 Linux 本地密码；sshd 的 PasswordAuthentication 是否允许仍由 SSH 策略决定。"
  confirm "确认进入 $u 的系统 passwd 流程？" || return 10
  passwd "$u"
}

lock_change() {
  require_root || return 1; local u="${1:-}" mode="${2:-}" current
  valid_user "$u" && getent passwd "$u" >/dev/null || return 64; current="$(_admin_session_user)"
  [[ "$u" != root ]] || { error "拒绝锁定 root"; return 30; }
  [[ "$mode" != lock || -z "$current" || "$u" != "$current" ]] || { error "拒绝锁定当前管理会话用户 $u"; return 30; }
  case "$mode" in
    lock)
      warn "这是整个账户锁定，不只是禁用密码；OpenSSH 可能因此拒绝该用户的公钥登录。"
      confirm "确认锁定整个账户 $u？" || return 10
      usermod -L "$u" || return 40
      ;;
    unlock)
      warn "解锁账户不会自动创建可用密码，也不会改变 sshd 的认证策略。"
      confirm "确认解锁账户 $u？" || return 10
      usermod -U "$u" || return 40
      ;;
    *) return 64;;
  esac
  log_event INFO "account lock state user=$u mode=$mode"; ok "$u: $mode"
}

remove_user() {
  require_root || return 1; local u="${1:-}" remove_home=0 current; shift || true
  valid_user "$u" || return 64; [[ "$u" != root ]] || { error "拒绝删除 root"; return 30; }; current="$(_admin_session_user)"
  [[ -z "$current" || "$u" != "$current" ]] || { error "拒绝删除当前管理会话用户 $u"; return 30; }
  getent passwd "$u" >/dev/null || { error "用户不存在: $u"; return 20; }
  while (($#)); do case "$1" in --remove-home) remove_home=1; shift;; --yes|-y) VPSG_ASSUME_YES=1; shift;; *) error "未知参数: $1"; return 64;; esac; done
  echo "将删除用户 $u。"; ((remove_home)) && echo "同时删除其 home 目录。"; confirm "确认删除？" || return 10
  if ((remove_home)); then userdel -r "$u"; else userdel "$u"; fi || return 40
  log_event INFO "user removed user=$u remove_home=$remove_home"; ok "用户已删除: $u"
}

bootstrap() {
  require_root || return 1
  local u="${1:-}" gh="${2:-}" existed=0 had_sudo=0 created=0
  valid_user "$u" || { error "用法: sudo vpsg users bootstrap <linux-user> <github-user> [--yes]"; return 64; }
  [[ "$gh" =~ ^[A-Za-z0-9-]{1,39}$ ]] || { error "GitHub 用户名格式无效"; return 64; }
  parse_yes_flag "$@"
  getent passwd "$u" >/dev/null && existed=1
  ((existed)) && is_sudo_user "$u" && had_sudo=1
  echo "管理员引导：确保用户 $u 存在 → sudo → 从 GitHub 导入 $gh 的公钥。"
  echo "完成后请新开 SSH 窗口，以 $u 登录并执行 sudo 验证。"
  confirm "继续？" || return 10
  if (( ! existed )); then _create_account "$u" 1 || return $?; created=1
  elif (( ! had_sudo )); then have sudo || DEBIAN_FRONTEND=noninteractive apt-get install -y sudo >/dev/null || return 40; usermod -aG sudo "$u" || return 40
  fi
  VPSG_ASSUME_YES=1 /bin/bash "$VPSG_ROOT/modules/builtin/ssh/module.sh" import-github "$gh" --user "$u" --yes
  local rc=$?
  if ((rc!=0)); then
    error "公钥导入失败，正在撤销本次 bootstrap 的账户权限变化。"
    if ((created)); then userdel -r "$u" >/dev/null 2>&1 || true
    elif (( ! had_sudo )); then gpasswd -d "$u" sudo >/dev/null 2>&1 || true
    fi
    return "$rc"
  fi
  log_event INFO "admin bootstrap user=$u github=$gh"
  ok "管理员用户已准备好。不要关闭当前会话；请先新开窗口验证: ssh $u@<server>，然后 sudo -v。"
}

menu() {
  list_users; echo; echo "1) 创建用户 2) 管理员 bootstrap 3) 授予sudo 4) 移除sudo 5) 禁用本地密码(保留公钥路径) 6) 设置本地密码 7) 锁定整个账户 8) 解锁整个账户 9) 删除用户 0) 返回"; read -r -p '请选择: ' c
  case "$c" in 1) read -r -p '用户名: ' u; add_user "$u";; 2) read -r -p 'Linux 用户名: ' u; read -r -p 'GitHub 用户名: ' gh; bootstrap "$u" "$gh";; 3) read -r -p '用户名: ' u; sudo_change "$u" enable;; 4) read -r -p '用户名: ' u; sudo_change "$u" disable;; 5) read -r -p '用户名: ' u; password_disable "$u";; 6) read -r -p '用户名: ' u; password_set "$u";; 7) read -r -p '用户名: ' u; lock_change "$u" lock;; 8) read -r -p '用户名: ' u; lock_change "$u" unlock;; 9) read -r -p '用户名: ' u; remove_user "$u";; esac
}

action="${1:-list}"; shift || true; parse_yes_flag "$@"
case "$action" in list|status|check) list_users;; add) add_user "$@";; bootstrap) bootstrap "$@";; sudo) sudo_change "$@";; password-disable) password_disable "${1:-}";; password-set) password_set "${1:-}";; lock) lock_change "${1:-}" lock;; unlock) lock_change "${1:-}" unlock;; remove) remove_user "$@";; menu) menu;; *) error "users 支持: list|add|bootstrap|sudo|password-disable|password-set|lock|unlock|remove|menu"; exit 64;; esac
