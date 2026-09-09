#!/usr/bin/env bash
set -uo pipefail
VPSG_ROOT="${VPSG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
. "$VPSG_ROOT/core/common.sh"
. "$VPSG_ROOT/core/platform.sh"
INSTALL_URL="${VPSG_1PANEL_INSTALL_URL:-https://resource.1panel.pro/v2/quick_start.sh}"

status() {
  if have 1pctl; then echo "1Panel: 已安装"; 1pctl status 2>/dev/null || true
  else echo "1Panel: 未安装"; fi
}
info_panel() { have 1pctl || { error "1Panel 未安装"; return 20; }; 1pctl user-info 2>/dev/null || { warn "无法读取 1Panel user-info"; return 30; }; }
plan() {
  cat <<PLAN
计划安装 1Panel：
  1. 从 HTTPS 官方地址下载安装脚本到临时文件（不会 curl | bash）
  2. 限制脚本大小，拒绝 HTML/错误页，并执行 bash -n
  3. 显示来源、SHA-256 和脚本预览
  4. 由管理员再次确认后才以 root 执行
官方安装源: $INSTALL_URL
注意：最终安装行为由 1Panel 官方脚本控制；VPS Guard 只负责安全下载边界与确认流程。
PLAN
}
install_panel() (
  set -uo pipefail
  require_root || return 1
  platform_supported || return 20
  have 1pctl && { warn "1Panel 已安装"; return 10; }
  [[ "$INSTALL_URL" == https://* ]] || { error "1Panel 安装源必须为 HTTPS"; return 64; }
  plan
  confirm "下载并检查 1Panel 官方安装脚本？" || return 10
  have curl || apt_install ca-certificates curl || return 40
  local tmp rc=0
  tmp="$(mktemp)" || return 40
  trap 'rm -f -- "$tmp"' EXIT
  download_bash_script_checked "$INSTALL_URL" "$tmp" || { rc=$?; error "下载安装脚本失败或安全检查未通过"; return "$rc"; }
  show_downloaded_script_summary "$tmp" "$INSTALL_URL" "1Panel upstream license/project terms"
  echo
  confirm "确认以 root 执行上面的 1Panel 官方安装脚本？" || return 10
  # Execute the privileged upstream installer with an explicit environment so
  # unrelated API tokens/credentials from the administrator shell are not
  # inherited by downloaded code.
  /usr/bin/env -i HOME=/root USER=root LOGNAME=root PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" LANG="${LANG:-C.UTF-8}" TERM="${TERM:-dumb}" /bin/bash "$tmp" || rc=$?
  if ((rc==0)); then log_event INFO "1panel installer completed url=$INSTALL_URL"; else error "1Panel 上游安装脚本返回 rc=$rc"; fi
  return "$rc"
)
menu() { status; echo; echo "1) 安装 1Panel 2) 查看登录信息 0) 返回"; read -r -p '请选择: ' c; case "$c" in 1) install_panel;; 2) info_panel;; esac; }
action="${1:-status}"; shift || true; parse_yes_flag "$@"
case "$action" in status|check) status;; plan) plan;; install|apply) install_panel;; info) info_panel;; menu) menu;; *) error "panel 支持: status|plan|install|info|menu"; exit 64;; esac
