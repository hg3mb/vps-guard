#!/usr/bin/env bash
set -uo pipefail
VPSG_ROOT="${VPSG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
. "$VPSG_ROOT/core/common.sh"
. "$VPSG_ROOT/core/platform.sh"

CONF="/etc/ssh/sshd_config.d/90-vps-guard.conf"
LAST="$VPSG_STATE_DIR/ssh-last-backup"

effective() { sshd -T 2>/dev/null; }
reload_ssh() { systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true; }

status() {
  local p="unknown"
  p="$(ssh_primary_port 2>/dev/null || true)"
  echo "SSH 端口: ${p:-无法唯一确认}"
  if have sshd; then
    effective | awk '$1 ~ /^(permitrootlogin|passwordauthentication|pubkeyauthentication|maxauthtries|logingracetime)$/ {print $1 ": " $2}'
  else
    warn "未找到 sshd"
  fi
}

plan() {
  cat <<'PLAN'
计划写入独立配置片段 /etc/ssh/sshd_config.d/90-vps-guard.conf：
  - 启用公钥认证
  - 禁止空密码
  - MaxAuthTries=4
  - LoginGraceTime=30s
不会修改 SSH 端口，不会自动关闭密码登录，也不会禁止 root 登录。
写入后会先执行 sshd -t；失败则立即恢复。
PLAN
}

apply() {
  require_root || return 1
  have sshd || { error "未找到 sshd"; return 20; }
  plan
  confirm "应用 SSH 安全配置？" || return 10
  ensure_runtime_dirs
  mkdir -p /etc/ssh/sshd_config.d
  local backup
  backup="$(managed_backup "$CONF" ssh)"
  printf '%s\n' "$backup" > "$LAST"
  cat > "$CONF" <<'CFG'
# Managed by VPS Guard
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 4
LoginGraceTime 30
CFG
  chmod 644 "$CONF"
  if ! sshd -t; then
    error "sshd 配置验证失败，正在恢复"
    rollback >/dev/null 2>&1 || true
    return 30
  fi
  reload_ssh
  verify || { error "SSH 生效验证失败"; return 50; }
  log_event INFO "ssh hardening applied"
  ok "SSH 安全配置已应用；端口和登录方式未被强制改变。"
}

verify() {
  have sshd || return 20
  local out; out="$(effective)"
  grep -q '^pubkeyauthentication yes$' <<<"$out" || return 1
  grep -q '^permitemptypasswords no$' <<<"$out" || return 1
  grep -q '^maxauthtries 4$' <<<"$out" || return 1
  grep -q '^logingracetime 30$' <<<"$out" || return 1
  ok "SSH 配置验证通过"
}

rollback() {
  require_root || return 1
  [[ -r "$LAST" ]] || { error "没有可用的 SSH 回滚点"; return 20; }
  local backup; backup="$(cat "$LAST")"
  if [[ -e "$backup" ]]; then
    cp -a "$backup" "$CONF"
  elif [[ -e "$backup.absent" ]]; then
    rm -f "$CONF"
  else
    error "回滚文件不存在"; return 60
  fi
  sshd -t || { error "恢复后的 SSH 配置仍未通过验证"; return 60; }
  reload_ssh
  ok "SSH 上次修改已回滚"
}

import_github() {
  require_root || return 1
  local gh="${1:-}"; shift || true
  [[ "$gh" =~ ^[A-Za-z0-9-]{1,39}$ ]] || { error "GitHub 用户名格式无效"; return 64; }
  local target="root"
  while (($#)); do
    case "$1" in
      --user) target="${2:-}"; shift 2 ;;
      --yes|-y) VPSG_ASSUME_YES=1; shift ;;
      *) error "未知参数: $1"; return 64 ;;
    esac
  done
  getent passwd "$target" >/dev/null || { error "用户不存在: $target"; return 64; }
  have curl || apt_install ca-certificates curl || return 40
  local home uid gid tmp
  IFS=: read -r _ _ uid gid _ home _ < <(getent passwd "$target")
  tmp="$(mktemp)"; trap 'rm -f "$tmp"' RETURN
  curl -fsSL --proto '=https' --tlsv1.2 "https://github.com/${gh}.keys" -o "$tmp" || { error "下载 GitHub 公钥失败"; return 40; }
  [[ -s "$tmp" ]] || { error "该 GitHub 用户没有公开 SSH key"; return 30; }
  if grep -Ev '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521))[[:space:]]+[A-Za-z0-9+/=]+([[:space:]].*)?$' "$tmp" | grep -q .; then
    error "返回内容包含无法识别的 SSH 公钥行"; return 30
  fi
  echo "将导入 $(wc -l < "$tmp" | tr -d ' ') 个公开密钥到用户 $target。"
  confirm "继续导入？" || return 10
  install -d -m 700 -o "$uid" -g "$gid" "$home/.ssh"
  local auth="$home/.ssh/authorized_keys"
  local backup; backup="$(managed_backup "$auth" "ssh-keys-$target")"
  touch "$auth"
  cat "$auth" "$tmp" | awk 'NF && !seen[$0]++' > "$auth.new"
  mv "$auth.new" "$auth"
  chown "$uid:$gid" "$auth"
  chmod 600 "$auth"
  log_event INFO "github ssh keys imported user=$target github=$gh backup=$backup"
  ok "公钥已导入。请保持当前 SSH 会话，并在新终端验证登录。"
}

action="${1:-status}"; shift || true
parse_yes_flag "$@"
case "$action" in
  status|check) status ;;
  plan) plan ;;
  apply) apply ;;
  verify) verify ;;
  rollback) rollback ;;
  import-github) import_github "$@" ;;
  doctor) have sshd && sshd -t && ok "sshd 配置语法正常" || exit 30 ;;
  *) error "ssh 支持: status|plan|apply|verify|rollback|import-github|doctor"; exit 64 ;;
esac
