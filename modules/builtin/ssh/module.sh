#!/usr/bin/env bash
set -uo pipefail
VPSG_ROOT="${VPSG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
. "$VPSG_ROOT/core/common.sh"
. "$VPSG_ROOT/core/platform.sh"
CONF="${VPSG_SSH_CONF:-$VPSG_SSH_CONFIG_DIR/00-vps-guard.conf}"
LEGACY_CONF="${VPSG_SSH_LEGACY_CONF:-$VPSG_SSH_CONFIG_DIR/90-vps-guard.conf}"
LAST="$VPSG_STATE_DIR/ssh-last"

_managed_config_paths_safe() {
  local f
  for f in "$CONF" "$LEGACY_CONF"; do
    assert_no_symlink_components "$(dirname "$f")" || return $?
    [[ ! -L "$f" ]] || { error "拒绝覆盖符号链接 SSH 配置: $f"; return 70; }
    [[ ! -e "$f" || -f "$f" ]] || { error "SSH 受管路径存在但不是普通文件: $f"; return 70; }
    if [[ -f "$f" ]] && ! vpsg_file_is_managed "$f"; then
      error "检测到同名但非 VPS Guard 管理的 SSH 配置，拒绝覆盖: $f"
      return 30
    fi
  done
}

prepare() {
  require_root || return 1
  _managed_config_paths_safe
}

effective() { sshd -T 2>/dev/null; }
reload_ssh() {
  have systemctl || return 20
  # Ubuntu 24.04 commonly uses ssh.socket. Port/ListenAddress changes are
  # consumed by sshd-socket-generator during daemon-reload, not by merely
  # reloading ssh.service.
  if systemctl is-active --quiet ssh.socket 2>/dev/null; then
    systemctl daemon-reload >/dev/null 2>&1 || return 40
    systemctl restart ssh.socket >/dev/null 2>&1 || return 40
  else
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null
  fi
}
admin_user() { if [[ -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != root ]]; then echo "$SUDO_USER"; else echo root; fi; }
has_admin_key() {
  local u home uid auth sshdir owner mode count
  u="$(admin_user)"; IFS=: read -r _ _ uid _ _ home _ < <(getent passwd "$u" 2>/dev/null)
  [[ "$uid" =~ ^[0-9]+$ && -n "$home" && "$home" == /* && "$home" != / ]] || return 1
  sshdir="$home/.ssh"; auth="$sshdir/authorized_keys"
  [[ -d "$sshdir" && ! -L "$sshdir" && -f "$auth" && ! -L "$auth" ]] || return 1
  count="$(authorized_keys_count_file "$auth")"; [[ "$count" =~ ^[0-9]+$ ]] && ((count>0)) || return 1
  # StrictModes-like sanity: key path must not be writable by group/others and
  # ownership must stay with the account or root. This still cannot prove a
  # future login, which is why Safe Change requires a new SSH session to commit.
  for path in "$home" "$sshdir" "$auth"; do
    owner="$(stat -c '%u' "$path" 2>/dev/null)" || return 1
    mode="$(stat -c '%a' "$path" 2>/dev/null)" || return 1
    [[ "$owner" == "$uid" || "$owner" == 0 ]] || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 8#022) == 0 )) || return 1
  done
}

status() {
  local p=unknown effective_port=unknown
  p="$(ssh_primary_port 2>/dev/null || true)"
  effective_port="$(ssh_effective_primary_port 2>/dev/null || true)"
  echo "当前管理端口: ${p:-无法唯一确认}"
  echo "SSH 实际配置端口: ${effective_port:-多个/无法唯一确认}"
  if have sshd; then
    effective | awk '$1 ~ /^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|maxauthtries|logingracetime)$/ {print $1 ": " $2}'
  else warn "未找到 sshd"; fi
  echo "当前管理用户: $(admin_user)"
  has_admin_key && echo "管理用户 authorized_keys: 已检测到" || echo "管理用户 authorized_keys: 未检测到"
  [[ ! -e "$LEGACY_CONF" ]] || warn "发现旧版 90-vps-guard.conf；下一次 Safe Change 会迁移到 00-vps-guard.conf。"
}

plan() { cat <<'PLAN'
默认安全配置：
  - PubkeyAuthentication yes
  - PermitEmptyPasswords no
  - MaxAuthTries 4
  - LoginGraceTime 30
可选：
  --disable-password  关闭密码/键盘交互登录（检测到当前管理员 SSH key 才允许）
  --root-key-only     root 只允许公钥登录（PermitRootLogin prohibit-password）
  --port <1-65535>    安全迁移 SSH 监听端口；若 UFW 已启用，新端口必须先放行

更换端口不会自动删除旧 UFW 规则。请在新端口登录并 commit 后，再手工清理旧端口。

VPS Guard 使用 00-vps-guard.conf，并在写入后同时执行 sshd -t 和 sshd -T。
OpenSSH 多数全局参数采用 first-obtained-value 语义，因此受管 drop-in 必须在常见 cloud-init drop-in 前加载。
所有 `vpsg ssh apply` 默认由 Safe Change 自动回滚保护。
PLAN
}

_backup_local_state() {
  ensure_runtime_dirs || return 40
  local d="$VPSG_BACKUP_DIR/ssh-module/$(date +%Y%m%d-%H%M%S)-$$" spec label file
  mkdir -p "$d" || return 40; chmod 700 "$d" 2>/dev/null || true
  for spec in "new:$CONF" "legacy:$LEGACY_CONF"; do
    label="${spec%%:*}"; file="${spec#*:}"
    if [[ -e "$file" ]]; then cp -a -- "$file" "$d/$label.conf" || return 40; echo present > "$d/$label.presence" || return 40
    else echo absent > "$d/$label.presence" || return 40; fi
  done
  printf '%s\n' "$d" | atomic_write_file "$LAST" 600 || return 40
  printf '%s\n' "$d"
}

_restore_local_state() {
  local d="$1" spec label target
  [[ -d "$d" ]] || return 60
  for spec in "new:$CONF" "legacy:$LEGACY_CONF"; do
    label="${spec%%:*}"; target="${spec#*:}"; mkdir -p "$(dirname "$target")" || return 60
    if grep -qx absent "$d/$label.presence" 2>/dev/null; then rm -f -- "$target" || return 60
    else cp -a -- "$d/$label.conf" "$target" || return 60; fi
  done
}

verify_config() {
  have sshd || return 20
  sshd -t >/dev/null 2>&1 || return 1
  local out key val got
  out="$(effective)" || return 1
  [[ -r "$CONF" ]] || return 1
  while read -r key val _; do
    [[ -n "$key" && "$key" != \#* ]] || continue
    key="${key,,}"; val="${val,,}"
    case "$key" in
      pubkeyauthentication|permitemptypasswords|maxauthtries|logingracetime|passwordauthentication|kbdinteractiveauthentication|permitrootlogin|port)
        got="$(awk -v k="$key" '$1==k {print tolower($2); exit}' <<<"$out")"
        [[ "$got" == "$val" ]] || { error "SSH 实际生效值不符合预期: $key expected=$val actual=${got:-missing}"; return 1; }
        ;;
    esac
  done < "$CONF"
}

verify_runtime() {
  local managed_port listeners
  managed_port="$(awk 'tolower($1)=="port" && $2 ~ /^[0-9]+$/ {print $2; exit}' "$CONF" 2>/dev/null)"
  [[ -n "$managed_port" ]] || return 0
  have ss || { error "SSH 已受管端口 $managed_port，但缺少 ss，无法验证实际监听"; return 1; }
  listeners="$(ss -H -ltn 2>/dev/null | awk '{print $4}')"
  grep -Eq "(^|:)${managed_port}$" <<<"$listeners" || { error "SSH 配置要求 $managed_port/tcp，但未检测到该监听端口"; return 1; }
}

verify() {
  verify_config || return $?
  verify_runtime || return $?
  ok "SSH 配置语法、实际生效值与受管监听验证通过"
}

apply() {
  require_root || return 1; have sshd || { error "未找到 sshd"; return 20; }
  _managed_config_paths_safe || return $?
  local disable_password=0 root_key_only=0 backup content new_port="" old_port="" fwline=""
  while (($#)); do case "$1" in
    --disable-password) disable_password=1; shift;;
    --root-key-only) root_key_only=1; shift;;
    --port) [[ $# -ge 2 ]] || return 64; new_port="$2"; shift 2;;
    --yes|-y) VPSG_ASSUME_YES=1; shift;;
    *) error "未知参数: $1"; return 64;;
  esac; done
  [[ -z "$new_port" ]] || valid_port "$new_port" || { error "SSH 端口必须为 1-65535"; return 64; }
  plan
  if ((disable_password)) && ! has_admin_key; then error "未检测到当前管理员 authorized_keys，拒绝关闭密码登录，避免失联"; return 30; fi
  if ((root_key_only)) && [[ "$(admin_user)" == root ]] && ! has_admin_key; then error "当前通过 root 管理但没有检测到 root authorized_keys，拒绝 root-key-only"; return 30; fi
  old_port="$(ssh_effective_primary_port 2>/dev/null || true)"
  if [[ -n "$new_port" && "$new_port" != "$old_port" ]] && have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
    fwline="$(ufw status 2>/dev/null | grep -E "^${new_port}/tcp([[:space:]]|$)" | head -1 || true)"
    grep -q 'ALLOW' <<<"$fwline" || { error "UFW 已启用但新 SSH 端口 $new_port/tcp 尚未放行。先执行: sudo vpsg firewall allow $new_port tcp"; return 30; }
  fi
  [[ -z "$new_port" || "$new_port" == "$old_port" ]] || echo "SSH 端口将从 ${old_port:-当前值} 迁移到 $new_port；Safe Change 会在失联时自动恢复。"
  confirm "应用 SSH 安全配置？" || return 10
  backup="$(_backup_local_state)" || return 40; mkdir -p "$(dirname "$CONF")" || return 40
  content="# Managed by VPS Guard v$VPSG_VERSION
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 4
LoginGraceTime 30"
  ((disable_password)) && content+=$'\nPasswordAuthentication no\nKbdInteractiveAuthentication no'
  ((root_key_only)) && content+=$'\nPermitRootLogin prohibit-password'
  [[ -z "$new_port" ]] || content+=$'\nPort '"$new_port"
  if ! printf '%s\n' "$content" | atomic_write_file "$CONF" 644; then _restore_local_state "$backup" >/dev/null 2>&1 || true; return 40; fi
  rm -f -- "$LEGACY_CONF" || { _restore_local_state "$backup" >/dev/null 2>&1 || true; return 40; }
  # Validate the new configuration before touching the running listener. A port
  # migration cannot pass runtime-listener verification until sshd/socket units
  # have actually been reloaded, so config and runtime verification are separate.
  if ! verify_config >/dev/null 2>&1; then
    error "SSH 新配置没有按预期解析，恢复修改前状态"
    _restore_local_state "$backup" >/dev/null 2>&1 || true
    return 30
  fi
  if ! reload_ssh; then
    error "sshd reload 失败，恢复修改前状态"
    _restore_local_state "$backup" >/dev/null 2>&1 || true
    sshd -t >/dev/null 2>&1 && reload_ssh >/dev/null 2>&1 || true
    return 40
  fi
  if ! verify; then
    error "SSH 运行状态验证失败，恢复修改前状态"
    _restore_local_state "$backup" >/dev/null 2>&1 || true
    sshd -t >/dev/null 2>&1 && reload_ssh >/dev/null 2>&1 || true
    return 50
  fi
  log_event INFO "ssh hardening applied disable_password=$disable_password root_key_only=$root_key_only"
  if [[ -n "$new_port" ]]; then
    ok "SSH 安全配置已应用。请新开终端验证: ssh -p $new_port $(admin_user)@<server>，成功后再执行 vpsg commit。"
  else
    ok "SSH 安全配置已应用。请新开 SSH 终端验证登录，再执行 vpsg commit。"
  fi
}

rollback() {
  require_root || return 1; [[ -r "$LAST" ]] || { error "没有可用的 SSH 模块回滚点"; return 20; }
  local backup; backup="$(cat "$LAST")"; [[ -d "$backup" ]] || return 60
  _restore_local_state "$backup" || return 60; sshd -t >/dev/null 2>&1 || return 60; reload_ssh || return 60; ok "SSH 上次模块修改已回滚"
}

import_github() (
  set -uo pipefail
  require_root || return 1
  local gh="${1:-}"; shift || true
  [[ "$gh" =~ ^[A-Za-z0-9-]{1,39}$ ]] || { error "GitHub 用户名格式无效"; return 64; }
  local target=root
  while (($#)); do case "$1" in --user) [[ $# -ge 2 ]] || return 64; target="$2"; shift 2;; --yes|-y) VPSG_ASSUME_YES=1; shift;; *) error "未知参数: $1"; return 64;; esac; done
  getent passwd "$target" >/dev/null || { error "用户不存在: $target"; return 64; }
  have curl || apt_install ca-certificates curl || return 40
  local home uid gid tmp auth backup sshdir
  IFS=: read -r _ _ uid gid _ home _ < <(getent passwd "$target")
  [[ -n "$home" && "$home" == /* && "$home" != / ]] || { error "用户 home 路径异常: ${home:-missing}"; return 30; }
  sshdir="$home/.ssh"; auth="$sshdir/authorized_keys"
  [[ ! -L "$sshdir" ]] || { error "拒绝写入符号链接 .ssh 目录: $sshdir"; return 30; }
  [[ ! -e "$sshdir" || -d "$sshdir" ]] || { error ".ssh 存在但不是目录: $sshdir"; return 30; }
  [[ ! -L "$auth" ]] || { error "拒绝覆盖符号链接 authorized_keys: $auth"; return 30; }
  [[ ! -e "$auth" || -f "$auth" ]] || { error "authorized_keys 存在但不是普通文件: $auth"; return 30; }
  tmp="$(mktemp)" || return 40; trap 'rm -f -- "$tmp"' EXIT
  curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 "https://github.com/${gh}.keys" -o "$tmp" || { error "下载 GitHub 公钥失败"; return 40; }
  [[ -s "$tmp" ]] || { error "该 GitHub 用户没有公开 SSH key"; return 30; }
  if grep -Ev '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]]+[A-Za-z0-9+/=]+([[:space:]].*)?$' "$tmp" | grep -q .; then error "返回内容包含无法识别的 SSH 公钥行"; return 30; fi
  echo "将导入 $(awk 'NF {n++} END {print n+0}' "$tmp") 个公开密钥到用户 $target。"
  confirm "继续导入？" || return 10
  install -d -m 700 -o "$uid" -g "$gid" "$sshdir" || return 40
  backup="$(managed_backup "$auth" "ssh-keys-$target")" || return 40
  { [[ ! -f "$auth" ]] || cat -- "$auth"; cat -- "$tmp"; } | awk 'NF && !seen[$0]++' | atomic_write_file_owned "$auth" 600 "$uid" "$gid" || return 40
  log_event INFO "github ssh keys imported user=$target github=$gh backup=$backup"
  ok "公钥已导入。请保持当前 SSH 会话，并在新终端验证登录。"
)

action="${1:-status}"; shift || true; parse_yes_flag "$@"
case "$action" in
  status|check) status;; prepare) prepare;; plan) plan;; apply) apply "$@";; verify) verify;; rollback) rollback;; import-github) import_github "$@";;
  doctor) have sshd && sshd -t && ok "sshd 配置语法正常" || exit 30;;
  *) error "ssh 支持: status|prepare|plan|apply [--disable-password] [--root-key-only] [--port N]|verify|rollback|import-github|doctor"; exit 64;;
esac
