#!/usr/bin/env bash
set -uo pipefail
VPSG_ROOT="${VPSG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
. "$VPSG_ROOT/core/common.sh"
. "$VPSG_ROOT/core/inspect.sh"

_docker_match() {
  local file="$1" proto="$2" port="$3"
  awk -F'\t' -v p="$proto" -v n="$port" '$2==p && $4==n {print $1 "@" $3 "->" $5 "/" $2}' "$file" 2>/dev/null | paste -sd, -
}

scan() {
  have ss || { error "Exposure Analyzer 需要 iproute2/ss"; return 20; }
  local tmp listeners docker
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  listeners="$tmp/listeners"; docker="$tmp/docker"
  inspect_listeners > "$listeners" || true
  inspect_docker_ports > "$docker" || true
  if [[ ! -s "$listeners" ]]; then echo "未检测到监听端口。"; return 0; fi

  printf '%-7s %-5s %-22s %-10s %-13s %-12s %s\n' "PORT" "PROTO" "BIND" "SCOPE" "FIREWALL" "CLASS" "OWNER / DOCKER"
  printf '%s\n' "---------------------------------------------------------------------------------------------------------------"
  local proto addr port scope process fw dm class owner
  while IFS=$'\t' read -r proto addr port scope process; do
    fw="$(inspect_ufw_port_policy "$port" "$proto")"
    dm="$(_docker_match "$docker" "$proto" "$port")"
    case "$scope" in
      loopback) class="LOCAL" ;;
      wildcard)
        if [[ -n "$dm" ]]; then class="DOCKER-PUB"; else class="NET-FACING"; fi ;;
      private) class="LAN/PRIVATE" ;;
      *) class="ADDR-BOUND" ;;
    esac
    owner="$process"; [[ -n "$dm" ]] && owner="$owner | $dm"
    printf '%-7s %-5s %-22s %-10s %-13s %-12s %s\n' "$port" "$proto" "$addr" "$scope" "$fw" "$class" "$owner"
  done < "$listeners"

  echo
  echo "说明：NET-FACING/DOCKER-PUB 表示服务绑定到可被外部接口接收的地址；是否真的能从互联网访问，还受云厂商安全组、上游防火墙、NAT 与 nftables/iptables 规则影响。"
  if [[ -s "$docker" ]]; then
    echo "Docker 映射单独标记为 DOCKER-PUB；不要只根据 UFW 状态判断 Docker 发布端口是否安全。"
  fi
}

explain() {
  local port="${1:-}"
  valid_port "$port" || { error "用法: vpsg exposure explain <port>"; return 64; }
  local tmp listeners docker found=0
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  listeners="$tmp/listeners"; docker="$tmp/docker"
  inspect_listeners > "$listeners" || true
  inspect_docker_ports > "$docker" || true
  echo "端口 $port 暴露分析"
  echo
  while IFS=$'\t' read -r proto addr p scope process; do
    [[ "$p" == "$port" ]] || continue
    found=1
    printf '监听: %s/%s  地址=%s  scope=%s\n' "$port" "$proto" "$addr" "$scope"
    printf '进程: %s\n' "$process"
    printf 'UFW: %s\n' "$(inspect_ufw_port_policy "$port" "$proto")"
  done < "$listeners"
  while IFS=$'\t' read -r name proto bind hp cp scope; do
    [[ "$hp" == "$port" ]] || continue
    found=1
    printf 'Docker: %s 发布 %s:%s -> %s/%s (%s)\n' "$name" "$bind" "$hp" "$cp" "$proto" "$scope"
  done < "$docker"
  (( found == 1 )) || { warn "当前没有检测到端口 $port 的监听或 Docker 发布映射"; return 10; }
  echo
  echo "判断建议：wildcard/DOCKER-PUB 应视为潜在公网入口；如它不是 Web/SSH 等预期服务，应检查绑定地址、Docker ports、UFW 以及云厂商安全组。"
}

json() {
  # Stable TSV-derived JSON without external jq dependency.
  have ss || { error "Exposure Analyzer 需要 ss"; return 20; }
  local tmp first=1 proto addr port scope process fw
  tmp="$(mktemp)"; trap 'rm -f "$tmp"' RETURN
  inspect_listeners > "$tmp" || true
  printf '{"listeners":['
  while IFS=$'\t' read -r proto addr port scope process; do
    (( first == 1 )) || printf ','; first=0
    fw="$(inspect_ufw_port_policy "$port" "$proto")"
    # process is sanitized to remove quotes to keep the no-jq fallback valid.
    process="${process//\\/\\\\}"; process="${process//\"/\\\"}"
    addr="${addr//\\/\\\\}"; addr="${addr//\"/\\\"}"
    printf '{"proto":"%s","address":"%s","port":%s,"scope":"%s","firewall":"%s","process":"%s"}' "$proto" "$addr" "$port" "$scope" "$fw" "$process"
  done < "$tmp"
  printf ']}\n'
}

action="${1:-scan}"; shift || true
case "$action" in
  status|scan|check) scan ;;
  explain) explain "$@" ;;
  json) json ;;
  *) error "exposure 支持: scan|status|explain <port>|json"; exit 64 ;;
esac
