#!/usr/bin/env bash
set -uo pipefail
VPSG_ROOT="${VPSG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
. "$VPSG_ROOT/core/common.sh"
. "$VPSG_ROOT/core/platform.sh"
status() { if have docker; then local v; v="$(docker --version 2>/dev/null || true)"; [[ "${1:-}" == "--brief" ]] && echo "已安装" || { echo "$v"; docker compose version 2>/dev/null || true; systemctl is-active docker 2>/dev/null || true; }; else [[ "${1:-}" == "--brief" ]] && echo "未安装" || echo "Docker: 未安装"; fi; }
plan() { cat <<'PLAN'
计划从 Debian/Ubuntu 发行版软件源安装 Docker（docker.io）。
会同时尝试安装 Compose v2；不会默认把普通用户加入 docker 组，因为 docker 组近似 root 权限。
PLAN
}
apply() { require_root || return 1; platform_supported || return 20; plan; confirm "安装 Docker？" || return 10; export DEBIAN_FRONTEND=noninteractive; apt-get update || return 40; apt-get install -y docker.io || return 40; if apt-cache show docker-compose-v2 >/dev/null 2>&1; then apt-get install -y docker-compose-v2 || true; elif apt-cache show docker-compose-plugin >/dev/null 2>&1; then apt-get install -y docker-compose-plugin || true; elif apt-cache show docker-compose >/dev/null 2>&1; then apt-get install -y docker-compose || true; fi; systemctl enable --now docker >/dev/null 2>&1 || return 40; verify || return 50; log_event INFO "docker installed from distro repository"; }
verify() { have docker || return 1; systemctl is-active --quiet docker 2>/dev/null || return 1; docker info >/dev/null 2>&1 || return 1; ok "Docker 运行正常"; }
list_containers() { have docker || { error "Docker 未安装"; return 20; }; docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'; }
ports() { have docker || return 20; docker ps --format 'table {{.Names}}\t{{.Ports}}'; }
add_user() { require_root || return 1; local u="${1:-}"; getent passwd "$u" >/dev/null || { error "用户不存在"; return 64; }; echo "警告：docker 组可以控制 Docker daemon，通常等价于 root 权限。"; confirm "仍要将 $u 加入 docker 组？" || return 10; usermod -aG docker "$u"; ok "已加入 docker 组；重新登录后生效"; }
menu() { status; echo; echo "1) 安装 2) 容器列表 3) 端口映射 4) 添加用户到 docker 组 0) 返回"; read -r -p '请选择: ' c; case "$c" in 1) apply;; 2) list_containers;; 3) ports;; 4) read -r -p '用户名: ' u; add_user "$u";; esac; }
action="${1:-status}"; shift || true; parse_yes_flag "$@"
case "$action" in status|check) status "$@";; plan) plan;; apply|install) apply;; verify) verify;; list) list_containers;; ports) ports;; add-user) add_user "$@";; menu) menu;; *) error "docker 支持: status|plan|apply|verify|list|ports|add-user|menu"; exit 64;; esac
