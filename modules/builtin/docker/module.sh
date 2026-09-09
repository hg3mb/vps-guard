#!/usr/bin/env bash
set -uo pipefail
VPSG_ROOT="${VPSG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
. "$VPSG_ROOT/core/common.sh"
. "$VPSG_ROOT/core/platform.sh"

KEY="$VPSG_APT_KEYRINGS_DIR/vps-guard-docker.asc"
SOURCE="$VPSG_APT_SOURCES_DIR/vps-guard-docker.sources"
CONFLICTS=(docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc)
CE_PKGS=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)

status() {
  if have docker; then
    [[ "${1:-}" == --brief ]] && { echo "已安装"; return; }
    docker --version 2>/dev/null || true; docker compose version 2>/dev/null || true
    if have systemctl; then systemctl is-active docker 2>/dev/null || true; fi
    docker info >/dev/null 2>&1 && echo "Docker daemon: 可访问" || echo "Docker daemon: 当前用户不可访问/未运行"
  else [[ "${1:-}" == --brief ]] && echo "未安装" || echo "Docker: 未安装"; fi
}

_installed_pkg() { dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null | grep -q '^ii'; }

_repo_paths_safe() {
  local p parent
  for p in "$KEY" "$SOURCE"; do
    parent="$(dirname "$p")"
    assert_no_symlink_components "$parent" || return $?
    [[ ! -L "$p" ]] || { error "拒绝使用符号链接 Docker 仓库文件: $p"; return 70; }
    [[ ! -e "$p" || -f "$p" ]] || { error "Docker 仓库路径存在但不是普通文件: $p"; return 70; }
  done
}
_installed_conflicts() { local p; for p in "${CONFLICTS[@]}"; do _installed_pkg "$p" && printf '%s\n' "$p"; done; }

plan() {
  platform_supported || { error "仅支持 Debian/Ubuntu"; return 20; }
  cat <<'PLAN'
计划使用 Docker 官方 APT 仓库安装 Docker CE + Compose v2。
- VPS Guard 使用自己拥有的 key/source 文件，不覆盖管理员已有 docker.asc/docker.sources。
- 冲突的发行版 Docker 包与 Docker CE 在同一个 APT 事务中替换，避免先卸载旧 Docker 再安装失败的窗口。
- 安装前执行 apt-get -s 模拟；若 APT 计划额外删除非预期软件包，会停止。
- 不会默认把普通用户加入 docker 组（docker 组通常等价于 root 级控制能力）。
- Docker Published Ports 不能仅凭 UFW INPUT 规则判断是否被阻断；请用 `vpsg exposure scan` 查看。
PLAN
  local c; c="$(_installed_conflicts)"; [[ -z "$c" ]] || { echo "当前冲突包:"; sed 's/^/  - /' <<<"$c"; }
}

_repo_backup() {
  local dir="$1"; _repo_paths_safe || return $?; mkdir -p "$dir" || return 40
  [[ -e "$KEY" ]] && cp -a "$KEY" "$dir/key" || : > "$dir/key.absent"
  [[ -e "$SOURCE" ]] && cp -a "$SOURCE" "$dir/source" || : > "$dir/source.absent"
}
_repo_restore() {
  local dir="$1"
  if [[ -e "$dir/key" ]]; then atomic_copy_file "$dir/key" "$KEY" "$(stat -c '%a' "$dir/key" 2>/dev/null || echo 644)"; else rm -f -- "$KEY"; fi
  if [[ -e "$dir/source" ]]; then atomic_copy_file "$dir/source" "$SOURCE" "$(stat -c '%a' "$dir/source" 2>/dev/null || echo 644)"; else rm -f -- "$SOURCE"; fi
}

# Print removals from apt simulation that are not in the explicitly allowed
# conflict set. Kept as a pure helper so regression tests can validate it.
_unexpected_removals() {
  local sim="$1" pkg allowed a
  while read -r _ pkg _; do
    [[ -n "$pkg" ]] || continue
    pkg="${pkg%%:*}"; allowed=0
    for a in "${CONFLICTS[@]}"; do [[ "$pkg" == "$a" ]] && allowed=1; done
    ((allowed)) || printf '%s\n' "$pkg"
  done < <(grep '^Remv ' "$sim" 2>/dev/null || true)
}

_write_repo() {
  platform_detect || return 20
  _repo_paths_safe || return $?
  local codename arch url
  codename="${VERSION_CODENAME:-}"; [[ -n "$codename" ]] || codename="$(. /etc/os-release; echo "${VERSION_CODENAME:-}")"
  [[ -n "$codename" ]] || { error "无法确认发行版 codename"; return 20; }
  arch="$(dpkg --print-architecture)"; url="https://download.docker.com/linux/$VPSG_OS_ID"
  mkdir -p "$VPSG_APT_KEYRINGS_DIR" "$VPSG_APT_SOURCES_DIR" || return 40; chmod 755 "$VPSG_APT_KEYRINGS_DIR" "$VPSG_APT_SOURCES_DIR"
  local tmp; tmp="$(mktemp)" || return 40
  if ! curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 "$url/gpg" -o "$tmp"; then rm -f "$tmp"; return 40; fi
  [[ -s "$tmp" ]] || { rm -f "$tmp"; return 40; }
  atomic_write_file "$KEY" 644 < "$tmp" || { rm -f "$tmp"; return 40; }; rm -f "$tmp"
  cat <<EOF_SOURCE | atomic_write_file "$SOURCE" 644 || return 40
# Managed by VPS Guard
Types: deb
URIs: $url
Suites: $codename
Components: stable
Architectures: $arch
Signed-By: $KEY
EOF_SOURCE
}

apply() {
  require_root || return 1; platform_supported || return 20
  plan; confirm "安装/升级到 Docker CE？" || return 10
  export DEBIAN_FRONTEND=noninteractive
  apt-get update >/dev/null || return 40
  apt-get install -y ca-certificates curl >/dev/null || return 40
  ensure_runtime_dirs || return 40
  local rb="$VPSG_STATE_DIR/docker-repo-rollback-$(date +%Y%m%d-%H%M%S)-$$"; _repo_backup "$rb" || return 40
  if ! _write_repo; then _repo_restore "$rb" || true; safe_rm_rf_within "$rb" "$VPSG_STATE_DIR" || true; error "Docker 官方仓库配置失败"; return 40; fi
  if ! apt-get update; then _repo_restore "$rb" || true; safe_rm_rf_within "$rb" "$VPSG_STATE_DIR" || true; error "Docker 仓库 apt update 失败，已恢复原软件源配置"; return 40; fi

  local -a args=("${CE_PKGS[@]}")
  local p; for p in "${CONFLICTS[@]}"; do _installed_pkg "$p" && args+=("${p}-"); done
  local sim unexpected; sim="$(mktemp)" || return 40
  if ! apt-get -s install "${args[@]}" > "$sim" 2>&1; then cat "$sim" >&2; rm -f "$sim"; _repo_restore "$rb" || true; error "Docker 安装模拟失败，未修改已安装包"; return 40; fi
  unexpected="$(_unexpected_removals "$sim")"
  if [[ -n "$unexpected" ]]; then
    error "APT 计划额外删除非预期软件包，已停止："; sed 's/^/  - /' <<<"$unexpected" >&2
    rm -f "$sim"; _repo_restore "$rb" || true; return 30
  fi
  echo "APT 模拟通过。计划替换的冲突包:"; _installed_conflicts | sed 's/^/  - /' || true; rm -f "$sim"
  if ! apt-get install -y "${args[@]}"; then _repo_restore "$rb" || true; error "Docker 包事务失败；仓库配置已恢复。APT 本身可能需要 `dpkg --configure -a` 继续恢复未完成事务。"; return 40; fi
  have systemctl && systemctl enable --now docker >/dev/null 2>&1 || true
  verify || return 50
  safe_rm_rf_within "$rb" "$VPSG_STATE_DIR" >/dev/null 2>&1 || true
  log_event INFO "docker CE installed official_repo=true"
  ok "Docker CE 安装完成。建议运行: sudo vpsg exposure scan"
}

verify() {
  have docker || return 1
  if have systemctl; then systemctl is-active --quiet docker 2>/dev/null || return 1; fi
  docker info >/dev/null 2>&1 || return 1
  docker compose version >/dev/null 2>&1 || warn "Docker Compose plugin 不可用"
  ok "Docker 运行正常"
}
list_containers() { have docker || { error "Docker 未安装"; return 20; }; docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'; }
ports() { have docker || return 20; docker ps --format 'table {{.Names}}\t{{.Ports}}'; }
add_user() { require_root || return 1; local u="${1:-}"; getent passwd "$u" >/dev/null || { error "用户不存在"; return 64; }; echo "警告：docker 组成员可以控制 Docker daemon，通常拥有接近 root 的权限。"; confirm "仍要将 $u 加入 docker 组？" || return 10; usermod -aG docker "$u" || return 40; ok "已加入 docker 组；重新登录后生效"; }
menu() { status; echo; echo "1) 安装/升级 Docker CE 2) 容器列表 3) 端口映射 4) 添加用户到 docker 组 0) 返回"; read -r -p '请选择: ' c; case "$c" in 1) apply;; 2) list_containers;; 3) ports;; 4) read -r -p '用户名: ' u; add_user "$u";; esac; }

action="${1:-status}"; shift || true; parse_yes_flag "$@"
case "$action" in status|check) status "$@";; plan) plan;; apply|install) apply;; verify) verify;; list) list_containers;; ports) ports;; add-user) add_user "$@";; menu) menu;; *) error "docker 支持: status|plan|apply|verify|list|ports|add-user|menu"; exit 64;; esac
