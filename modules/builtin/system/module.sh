#!/usr/bin/env bash
set -uo pipefail
VPSG_ROOT="${VPSG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
. "$VPSG_ROOT/core/common.sh"
. "$VPSG_ROOT/core/platform.sh"
status() { platform_detect || return 20; printf '系统: %s\n内核: %s\n内存: %s MB\n根分区可用: %s MB\n' "$VPSG_OS_PRETTY" "$(uname -r)" "$(memory_mb)" "$(root_free_mb)"; [[ -e /var/run/reboot-required ]] && echo "重启: 当前已有 reboot-required" || true; }
plan() {
  platform_supported || { error "仅支持 Debian/Ubuntu"; return 20; }; have apt-get || return 20
  echo "系统更新风险检查（只读）"; local list total sec kernel ssh docker
  list="$(apt list --upgradable 2>/dev/null | sed '1d' || true)"; total="$(grep -c . <<<"$list" 2>/dev/null || true)"; [[ -z "$list" ]] && total=0
  sec="$(grep -ci 'security' <<<"$list" || true)"; kernel="$(grep -Ec '^(linux-image|linux-headers|linux-generic)' <<<"$list" || true)"; ssh="$(grep -Ec '^openssh-' <<<"$list" || true)"; docker="$(grep -Ec '^(docker|containerd)' <<<"$list" || true)"
  printf '可升级软件包: %s\n安全源相关: %s\nKernel 相关: %s\nOpenSSH 相关: %s\nDocker/containerd 相关: %s\n根分区可用: %s MB\n' "$total" "$sec" "$kernel" "$ssh" "$docker" "$(root_free_mb)"
  (( kernel > 0 )) && warn "包含内核更新，安装后可能需要重启"; (( ssh > 0 )) && warn "包含 OpenSSH 更新，升级后应验证 SSH 仍可连接"; (( docker > 0 )) && warn "包含 Docker/containerd 更新，请关注运行中的容器"
  echo "实际升级: sudo vpsg system apply"
}
apply() { require_root || return 1; platform_supported || return 20; plan; confirm "执行 apt upgrade？不会自动重启。" || return 10; export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get upgrade -y || return 40; log_event INFO "system update completed"; echo; status; have sshd && sshd -t && ok "升级后 sshd 配置验证通过" || true; have docker && systemctl is-active --quiet docker && ok "Docker 仍在运行" || true; }
action="${1:-status}"; shift || true; parse_yes_flag "$@"
case "$action" in check|status) status;; plan) plan;; update|apply) apply;; doctor) platform_supported && ok "$VPSG_OS_PRETTY" || exit 20;; *) error "system 支持: status|plan|apply|doctor"; exit 64;; esac
