#!/usr/bin/env bash
set -uo pipefail
VPSG_ROOT="${VPSG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
. "$VPSG_ROOT/core/common.sh"
. "$VPSG_ROOT/core/platform.sh"
AUTO_CONF="$VPSG_APT_CONF_DIR/52vps-guard-auto-upgrades"
AUTO_STATE="$VPSG_STATE_DIR/auto-updates-last-backup"

status() {
  platform_detect || return 20
  printf '系统: %s\n内核: %s\n内存: %s MB\n根分区可用: %s MB\n' "$VPSG_OS_PRETTY" "$(uname -r)" "$(memory_mb)" "$(root_free_mb)"
  [[ -e /var/run/reboot-required ]] && echo "重启: 当前已有 reboot-required" || echo "重启: 当前未检测到 reboot-required"
  printf '自动安全更新: '; auto_status --brief
}

_simulate_upgrade() { apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null; }
plan() {
  platform_supported || { error "仅支持 Debian/Ubuntu"; return 20; }; have apt-get || return 20
  local sim total kernel ssh docker held free
  if ! sim="$(_simulate_upgrade)"; then error "apt-get 模拟升级失败；未执行任何升级。"; return 30; fi
  total="$(grep -c '^Inst ' <<<"$sim" || true)"; kernel="$(grep '^Inst ' <<<"$sim" | grep -Ec ' (linux-image|linux-headers|linux-generic|linux-base)' || true)"
  ssh="$(grep '^Inst ' <<<"$sim" | grep -Ec ' openssh-(server|client|sftp-server)' || true)"; docker="$(grep '^Inst ' <<<"$sim" | grep -Ec ' (docker|docker-ce|containerd|containerd.io)' || true)"
  held="$(apt-mark showhold 2>/dev/null | wc -l | tr -d ' ')"; free="$(root_free_mb)"
  echo "系统更新风险检查（apt-get -s，仅模拟，不修改系统）"
  printf '计划升级: %s 个包\nKernel 相关: %s\nOpenSSH 相关: %s\nDocker/containerd 相关: %s\nHeld packages: %s\n根分区可用: %s MB\n' "$total" "$kernel" "$ssh" "$docker" "$held" "$free"
  ((free < 1024)) && warn "根分区可用空间低于 1GB，建议先释放空间"
  ((kernel>0)) && warn "包含内核更新，完成后可能需要重启"
  ((ssh>0)) && warn "包含 OpenSSH 更新，升级后应保持当前会话并新开 SSH 窗口验证"
  ((docker>0)) && warn "包含 Docker/containerd 更新，请检查运行中的容器"
  echo "执行升级: sudo vpsg system apply"
}

apply() {
  require_root || return 1; platform_supported || return 20
  apt-get update || return 40; plan || return $?; confirm "执行 apt upgrade？VPS Guard 不会自动重启。" || return 10
  export DEBIAN_FRONTEND=noninteractive
  apt-get upgrade -y || return 40
  log_event INFO "system upgrade completed"
  echo; status
  if have sshd; then sshd -t && ok "升级后 sshd 配置语法正常" || warn "升级后 sshd 配置验证失败"; fi
  if have docker; then docker info >/dev/null 2>&1 && ok "Docker daemon 可访问" || warn "升级后 Docker daemon 需要检查"; fi
  [[ -e /var/run/reboot-required ]] && warn "系统提示需要重启；请在确认服务正常后自行安排。"
}

auto_status() {
  if [[ -r "$AUTO_CONF" ]] && grep -q 'APT::Periodic::Unattended-Upgrade "1"' "$AUTO_CONF"; then [[ "${1:-}" == --brief ]] && echo "已启用" || { echo "自动安全更新: 已启用"; echo "自动重启: 禁用"; }; else [[ "${1:-}" == --brief ]] && echo "未启用" || echo "自动安全更新: 未启用"; fi
}
auto_enable() {
  require_root || return 1; platform_supported || return 20
  confirm "启用 Debian/Ubuntu unattended-upgrades 定期更新？不会自动重启。" || return 10
  DEBIAN_FRONTEND=noninteractive apt-get update >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades apt-listchanges >/dev/null || return 40
  ensure_runtime_dirs || return 40
  local backup; backup="$(managed_backup "$AUTO_CONF" auto-updates)" || return 40; printf '%s\n' "$backup" | atomic_write_file "$AUTO_STATE" 600 || return 40
  cat <<'EOF_CONF' | atomic_write_file "$AUTO_CONF" 644 || return 40
// Managed by VPS Guard. Distribution policy in 50unattended-upgrades remains authoritative.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
Unattended-Upgrade::Automatic-Reboot "false";
EOF_CONF
  if ! apt-config dump >/dev/null 2>&1; then auto_rollback >/dev/null 2>&1 || true; error "APT 配置验证失败，已恢复原配置"; return 50; fi
  log_event INFO "automatic updates enabled auto_reboot=false"; ok "自动更新已启用；不会由 VPS Guard 自动重启。"
}
auto_disable() { require_root || return 1; confirm "停用 VPS Guard 的自动更新开关？不会卸载 unattended-upgrades。" || return 10; rm -f -- "$AUTO_CONF"; log_event INFO "automatic updates disabled"; ok "VPS Guard 自动更新配置已停用"; }
auto_rollback() {
  require_root || return 1; [[ -r "$AUTO_STATE" ]] || { error "没有自动更新回滚点"; return 20; }
  local b; b="$(cat "$AUTO_STATE")"; [[ "$b" == "$VPSG_BACKUP_DIR"/auto-updates/* ]] || { error "自动更新回滚路径不可信"; return 70; }
  if [[ -f "$b" ]]; then atomic_copy_file "$b" "$AUTO_CONF" "$(stat -c '%a' "$b" 2>/dev/null || echo 644)" || return 40
  elif [[ -e "$b.absent" ]]; then rm -f -- "$AUTO_CONF"
  else error "回滚备份不存在"; return 20; fi
  apt-config dump >/dev/null 2>&1 || return 50; ok "自动更新配置已回滚"
}

action="${1:-status}"; shift || true; parse_yes_flag "$@"
case "$action" in
  check|status) status;; plan) plan;; update|apply) apply;; doctor) platform_supported && ok "$VPSG_OS_PRETTY" || exit 20;;
  auto-status) auto_status "$@";; auto-enable) auto_enable;; auto-disable) auto_disable;; auto-rollback) auto_rollback;;
  *) error "system 支持: status|plan|apply|doctor|auto-status|auto-enable|auto-disable|auto-rollback"; exit 64;;
esac
