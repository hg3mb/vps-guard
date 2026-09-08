#!/usr/bin/env bash
set -uo pipefail
VPSG_ROOT="${VPSG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
. "$VPSG_ROOT/core/common.sh"
. "$VPSG_ROOT/core/platform.sh"
INSTALL_URL="${VPSG_1PANEL_INSTALL_URL:-https://resource.1panel.pro/v2/quick_start.sh}"

status() {
  if have 1pctl; then echo "1Panel: 已安装"; 1pctl status 2>/dev/null || true; else echo "1Panel: 未安装"; fi
}
info_panel() { have 1pctl || { error "1Panel 未安装"; return 20; }; 1pctl user-info 2>/dev/null || { warn "无法读取 1Panel user-info"; return 30; }; }
plan() {
  cat <<PLAN
计划安装 1Panel：
  1. 从官方地址下载安装脚本到临时文件（不会 curl | bash）
  2. 拒绝 HTML/空文件，显示 SHA-256 和脚本前几行
  3. 由你再次确认后才执行
官方安装源: $INSTALL_URL
安装过程由 1Panel 官方脚本交互完成。
PLAN
}
install_panel() {
  require_root || return 1; platform_supported || return 20; have 1pctl && { warn "1Panel 已安装"; return 10; }; plan; confirm "下载并检查 1Panel 官方安装脚本？" || return 10
  have curl || apt_install ca-certificates curl || return 40
  local tmp; tmp="$(mktemp)"; trap 'rm -f "$tmp"' RETURN
  curl -fL --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 60 "$INSTALL_URL" -o "$tmp" || { error "下载安装脚本失败"; return 40; }
  [[ -s "$tmp" ]] || { error "安装脚本为空"; return 40; }; if grep -Eiq '<!doctype|<html|cloudflare|just a moment' "$tmp"; then error "下载内容看起来是网页而不是 shell 脚本，拒绝执行"; return 40; fi
  echo "SHA-256: $(sha256sum "$tmp" | awk '{print $1}')"; echo "脚本预览:"; sed -n '1,12p' "$tmp"; echo
  confirm "确认执行上面的 1Panel 官方安装脚本？" || return 10
  /bin/bash "$tmp"; local rc=$?; (( rc == 0 )) && log_event INFO "1panel installer completed url=$INSTALL_URL"; return "$rc"
}
menu() { status; echo; echo "1) 安装 1Panel 2) 查看登录信息 0) 返回"; read -r -p '请选择: ' c; case "$c" in 1) install_panel;; 2) info_panel;; esac; }
action="${1:-status}"; shift || true; parse_yes_flag "$@"
case "$action" in status|check) status;; plan) plan;; install|apply) install_panel;; info) info_panel;; menu) menu;; *) error "panel 支持: status|plan|install|info|menu"; exit 64;; esac
