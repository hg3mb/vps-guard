#!/usr/bin/env bash
set -uo pipefail
VPSG_ROOT="${VPSG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
. "$VPSG_ROOT/core/common.sh"
. "$VPSG_ROOT/core/platform.sh"

YABS_URL="${VPSG_YABS_URL:-https://raw.githubusercontent.com/masonr/yet-another-bench-script/master/yabs.sh}"
REGION_URL="${VPSG_REGION_URL:-https://raw.githubusercontent.com/lmc999/RegionRestrictionCheck/main/check.sh}"

summary() {
  echo "网络摘要"
  echo "默认 IPv4 路由: $(ip -4 route show default 2>/dev/null | head -1 || echo unavailable)"
  echo "默认 IPv6 路由: $(ip -6 route show default 2>/dev/null | head -1 || echo unavailable)"
  if have curl; then
    printf '公网 IPv4: '; curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null || echo unavailable; echo
    printf '公网 IPv6: '; curl -6 -fsS --max-time 6 https://api64.ipify.org 2>/dev/null || echo unavailable; echo
  else warn "安装 curl 后可查询公网 IP"; fi
  echo "DNS: $(awk '/^nameserver/ {printf "%s ",$2}' /etc/resolv.conf 2>/dev/null)"
}

speed() {
  have curl || { error "speed 需要 curl"; return 20; }
  local mb="${1:-25}"
  [[ "$mb" =~ ^[0-9]+$ ]] && ((mb>=1 && mb<=200)) || { error "用法: vpsg network speed [1-200 MB]"; return 64; }
  local bytes=$((mb*1000000))
  echo "下载 ${mb} MB 测试文件（Cloudflare），仅作快速参考..."
  curl -fL --proto '=https' --proto-redir '=https' --tlsv1.2 --max-time 90 -o /dev/null -sS \
    -w 'HTTP=%{http_code}\nTime=%{time_total}s\nAverage=%{speed_download} bytes/s\n' \
    "https://speed.cloudflare.com/__down?bytes=$bytes" || { error "测速失败"; return 40; }
}

route_test() {
  local target="${1:-1.1.1.1}"
  [[ -n "$target" && "$target" != -* && "$target" != *$'\n'* ]] || { error "无效目标"; return 64; }
  echo "到 $target 的路由"
  if have mtr; then mtr -rwzc 10 -- "$target"
  elif have traceroute; then traceroute -- "$target"
  else echo "缺少 mtr/traceroute。可运行: sudo apt install mtr-tiny traceroute"; return 20
  fi
}

probe_one() {
  local name="$1" url="$2" code
  code="$(curl -L --proto '=https' --proto-redir '=https' --tlsv1.2 -A 'Mozilla/5.0' -o /dev/null -sS --connect-timeout 6 --max-time 12 -w '%{http_code}' "$url" 2>/dev/null || echo 000)"
  if [[ "$code" =~ ^(200|204|301|302|307|308|403)$ ]]; then
    printf '%-14s reachable (HTTP %s)\n' "$name" "$code"
  else
    printf '%-14s unavailable/blocked (HTTP %s)\n' "$name" "$code"
  fi
}

media() {
  have curl || { error "media 需要 curl"; return 20; }
  echo "流媒体可达性快速检查（不是完整解锁/地区判定）"
  probe_one Netflix https://www.netflix.com/
  probe_one YouTube https://www.youtube.com/
  probe_one DisneyPlus https://www.disneyplus.com/
  probe_one PrimeVideo https://www.primevideo.com/
  echo "提示：CDN、账号地区、DNS 和服务商策略都会影响实际播放结果。"
}

bench() {
  echo "轻量 VPS 信息"
  echo "CPU: $(nproc) cores — $(awk -F: '/model name/ {gsub(/^ +/,"",$2); print $2; exit}' /proc/cpuinfo)"
  echo "内存: $(memory_mb) MB"
  echo "磁盘根分区:"; df -h / | tail -1; echo
  summary
}

_invoking_nonroot_user() {
  if (( EUID != 0 )); then id -un; return 0; fi
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]] && id "$SUDO_USER" >/dev/null 2>&1; then printf '%s\n' "$SUDO_USER"; return 0; fi
  return 1
}

_run_external_as_user() {
  local script="$1"; shift
  local u home
  if (( EUID != 0 )); then /bin/bash "$script" "$@"; return $?; fi
  u="$(_invoking_nonroot_user)" || {
    error "第三方检测脚本不会由 root 运行。请退出 root shell，以普通用户执行；如需要可由 VPS Guard 自身功能使用 sudo。"
    return 30
  }
  have runuser || { error "缺少 runuser，无法安全降权运行第三方脚本"; return 20; }
  home="$(getent passwd "$u" | awk -F: '{print $6}')"; [[ -d "$home" ]] || home="/tmp"
  # Root downloads external scripts as mode 0600. Do not make the file
  # user-writable just to downgrade execution: grant the target user's primary
  # group read-only access for the short execution window, then restore it.
  local old_mode old_gid target_gid rc=0
  old_mode="$(stat -c '%a' "$script" 2>/dev/null)" || return 40
  old_gid="$(stat -c '%g' "$script" 2>/dev/null)" || return 40
  target_gid="$(id -g "$u" 2>/dev/null)" || return 40
  chgrp "$target_gid" "$script" || return 40
  chmod 0440 "$script" || { chgrp "$old_gid" "$script" 2>/dev/null || true; return 40; }
  # Do not leak the invoking root shell's credentials/tokens into optional
  # third-party code. `env -i` establishes an explicit minimal environment.
  # Users who need a proxy can run the integration directly as their own user
  # with the desired environment instead of passing root secrets through VPS Guard.
  runuser -u "$u" -- env -i HOME="$home" USER="$u" LOGNAME="$u" PATH="/usr/local/bin:/usr/bin:/bin" LANG="${LANG:-C.UTF-8}" TERM="${TERM:-dumb}" /bin/bash "$script" "$@" || rc=$?
  chgrp "$old_gid" "$script" 2>/dev/null || true
  chmod "$old_mode" "$script" 2>/dev/null || true
  return "$rc"
}

_external_script() (
  set -uo pipefail
  local name="$1" url="$2" license="$3" warning="$4"; shift 4
  have curl || { error "$name 需要 curl"; return 20; }
  local tmp
  # When root will later drop privileges, place the staged public script under
  # a traversable sticky directory. A private TMPDIR could otherwise make a
  # correctly group-readable file unreachable to the target user.
  if (( EUID == 0 )); then tmp="$(mktemp /var/tmp/vpsg-external.XXXXXX)" || return 40
  else tmp="$(mktemp)" || return 40
  fi
  trap 'rm -f -- "$tmp"' EXIT
  info "$name 是第三方项目，VPS Guard 不把其代码复制进仓库，也不会直接 curl | bash。"
  echo "$warning"
  confirm "下载并检查 $name 上游脚本？" || return 10
  download_bash_script_checked "$url" "$tmp" || { local rc=$?; error "$name 下载/检查失败"; return "$rc"; }
  show_downloaded_script_summary "$tmp" "$url" "$license"
  echo
  confirm "确认以非 root 身份运行这份已检查的 $name 脚本？" || return 10
  _run_external_as_user "$tmp" "$@"
)

yabs() {
  _external_script \
    "YABS" "$YABS_URL" "WTFPL v2 (upstream)" \
    "注意：YABS 会下载并运行 fio/iperf/Geekbench 等上游工具，完整测试可能消耗数 GB 流量并持续较长时间。" "$@"
}

region() {
  _external_script \
    "RegionRestrictionCheck" "$REGION_URL" "AGPL-3.0 (upstream)" \
    "注意：该第三方脚本会访问多个流媒体/网络服务用于地区与可用性检测；结果可能受 DNS、IP 库和服务策略影响。" "$@"
}

menu() {
  echo "1) 网络摘要"
  echo "2) 快速下载测速"
  echo "3) 路由追踪"
  echo "4) 流媒体快速可达性"
  echo "5) VPS 轻量信息"
  echo "6) YABS 完整基准测试（第三方/非 root）"
  echo "7) RegionRestrictionCheck（第三方/非 root）"
  echo "0) 返回"
  read -r -p '请选择: ' c
  case "$c" in
    1) summary;; 2) speed 25;;
    3) read -r -p '目标IP/域名 [1.1.1.1]: ' t; route_test "${t:-1.1.1.1}";;
    4) media;; 5) bench;; 6) yabs;; 7) region;;
  esac
}

action="${1:-summary}"; shift || true
case "$action" in
  summary|status|check) summary;; speed) speed "$@";; route) route_test "$@";; media) media;; bench) bench;;
  yabs) yabs "$@";; region|streaming) region "$@";; menu) menu;;
  *) error "network 支持: summary|speed [MB]|route [target]|media|bench|yabs|region|menu"; exit 64;;
esac
