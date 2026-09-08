#!/usr/bin/env bash
set -uo pipefail
VPSG_ROOT="${VPSG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
. "$VPSG_ROOT/core/common.sh"
. "$VPSG_ROOT/core/platform.sh"

action="${1:-status}"; shift || true
case "$action" in
  check|status)
    platform_detect || { error "无法识别系统"; exit 20; }
    printf '系统: %s\n' "$VPSG_OS_PRETTY"
    printf '内核: %s\n' "$(uname -r)"
    printf '内存: %s MB\n' "$(memory_mb)"
    printf '根分区可用: %s MB\n' "$(root_free_mb)"
    ;;
  plan)
    echo "计划：刷新 APT 索引并安装可用升级；不自动重启服务器。"
    ;;
  update|apply)
    require_root || exit 1
    platform_supported || { error "仅支持 Debian/Ubuntu"; exit 20; }
    confirm "执行系统软件更新？" || exit 10
    export DEBIAN_FRONTEND=noninteractive
    apt-get update && apt-get upgrade -y
    log_event INFO "system update completed"
    ;;
  doctor)
    platform_supported && ok "$VPSG_OS_PRETTY" || { warn "不受支持的系统"; exit 20; }
    have apt-get && ok "APT 可用" || { warn "APT 不可用"; exit 20; }
    ;;
  *) error "system 支持: status|check|plan|update|apply|doctor"; exit 64 ;;
esac
