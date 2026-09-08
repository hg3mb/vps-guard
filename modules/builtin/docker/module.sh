#!/usr/bin/env bash
set -uo pipefail
VPSG_ROOT="${VPSG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
. "$VPSG_ROOT/core/common.sh"
. "$VPSG_ROOT/core/platform.sh"

status() {
  if have docker; then
    local v; v="$(docker --version 2>/dev/null || true)"
    [[ "${1:-}" == "--brief" ]] && echo "已安装" || { echo "$v"; docker compose version 2>/dev/null || true; }
  else
    [[ "${1:-}" == "--brief" ]] && echo "未安装" || echo "Docker: 未安装"
  fi
}

plan() {
  cat <<'PLAN'
计划从 Debian/Ubuntu 当前发行版软件源安装 Docker（docker.io）。
如发行版提供 Compose v2 插件则一并安装，否则尝试 docker-compose。
不会自动把普通用户加入 docker 组（该组近似 root 权限）。
PLAN
}

apply() {
  require_root || return 1
  platform_supported || { error "仅支持 Debian/Ubuntu"; return 20; }
  plan
  confirm "安装 Docker？" || return 10
  export DEBIAN_FRONTEND=noninteractive
  apt-get update || return 40
  apt-get install -y docker.io || return 40
  if apt-cache show docker-compose-v2 >/dev/null 2>&1; then apt-get install -y docker-compose-v2 || true
  elif apt-cache show docker-compose-plugin >/dev/null 2>&1; then apt-get install -y docker-compose-plugin || true
  elif apt-cache show docker-compose >/dev/null 2>&1; then apt-get install -y docker-compose || true
  fi
  systemctl enable --now docker >/dev/null 2>&1 || return 40
  verify || return 50
  log_event INFO "docker installed from distro repository"
}

verify() {
  have docker || return 1
  systemctl is-active --quiet docker 2>/dev/null || return 1
  docker info >/dev/null 2>&1 || return 1
  ok "Docker 运行正常"
}

action="${1:-status}"; shift || true
parse_yes_flag "$@"
case "$action" in
  status|check) status "$@" ;;
  plan) plan ;;
  apply) apply ;;
  verify) verify ;;
  *) error "docker 支持: status|plan|apply|verify"; exit 64 ;;
esac
