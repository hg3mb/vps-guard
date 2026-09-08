#!/usr/bin/env bash
set -uo pipefail
VPSG_ROOT="${VPSG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
. "$VPSG_ROOT/core/common.sh"
. "$VPSG_ROOT/core/platform.sh"

summary() {
  echo "网络摘要"; echo "默认 IPv4 路由: $(ip -4 route show default 2>/dev/null | head -1 || echo unavailable)"; echo "默认 IPv6 路由: $(ip -6 route show default 2>/dev/null | head -1 || echo unavailable)"
  if have curl; then
    printf '公网 IPv4: '; curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null || echo unavailable; echo
    printf '公网 IPv6: '; curl -6 -fsS --max-time 6 https://api64.ipify.org 2>/dev/null || echo unavailable; echo
  else warn "安装 curl 后可查询公网 IP"; fi
  echo "DNS: $(awk '/^nameserver/ {printf "%s ",$2}' /etc/resolv.conf 2>/dev/null)"
}

speed() {
  have curl || { error "speed 需要 curl"; return 20; }
  local mb="${1:-25}"; [[ "$mb" =~ ^[0-9]+$ ]] && ((mb>=1 && mb<=200)) || { error "用法: vpsg network speed [1-200 MB]"; return 64; }
  local bytes=$((mb*1000000)); echo "下载 ${mb} MB 测试文件（Cloudflare），仅作快速参考..."
  curl -fL --max-time 90 -o /dev/null -sS -w 'HTTP=%{http_code}\nTime=%{time_total}s\nAverage=%{speed_download} bytes/s\n' "https://speed.cloudflare.com/__down?bytes=$bytes" || { error "测速失败"; return 40; }
}

route_test() {
  local target="${1:-1.1.1.1}"; echo "到 $target 的路由"
  if have mtr; then mtr -rwzc 10 "$target"; elif have traceroute; then traceroute "$target"; else echo "缺少 mtr/traceroute。可运行: sudo apt install mtr-tiny traceroute"; return 20; fi
}

probe_one() {
  local name="$1" url="$2" code
  code="$(curl -L -A 'Mozilla/5.0' -o /dev/null -sS --connect-timeout 6 --max-time 12 -w '%{http_code}' "$url" 2>/dev/null || echo 000)"
  if [[ "$code" =~ ^(200|204|301|302|307|308|403)$ ]]; then printf '%-14s reachable (HTTP %s)\n' "$name" "$code"; else printf '%-14s unavailable/blocked (HTTP %s)\n' "$name" "$code"; fi
}
media() {
  have curl || { error "media 需要 curl"; return 20; }
  echo "流媒体可达性快速检查（不是完整解锁/地区判定）"; probe_one Netflix https://www.netflix.com/; probe_one YouTube https://www.youtube.com/; probe_one DisneyPlus https://www.disneyplus.com/; probe_one PrimeVideo https://www.primevideo.com/
  echo "提示：CDN、账号地区、DNS 和服务商策略都会影响实际播放结果。"
}

bench() { echo "轻量 VPS 信息"; echo "CPU: $(nproc) cores — $(awk -F: '/model name/ {gsub(/^ +/,"",$2); print $2; exit}' /proc/cpuinfo)"; echo "内存: $(memory_mb) MB"; echo "磁盘根分区:"; df -h / | tail -1; echo; summary; }
menu() { echo "1) 网络摘要 2) 快速下载测速 3) 路由追踪 4) 流媒体可达性 5) VPS 轻量信息 0) 返回"; read -r -p '请选择: ' c; case "$c" in 1) summary;; 2) speed 25;; 3) read -r -p '目标IP/域名 [1.1.1.1]: ' t; route_test "${t:-1.1.1.1}";; 4) media;; 5) bench;; esac; }
action="${1:-summary}"; shift || true
case "$action" in summary|status|check) summary;; speed) speed "$@";; route) route_test "$@";; media) media;; bench) bench;; menu) menu;; *) error "network 支持: summary|speed [MB]|route [target]|media|bench|menu"; exit 64;; esac
