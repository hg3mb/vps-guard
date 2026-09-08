#!/usr/bin/env bash
set -uo pipefail
VPSG_ROOT="${VPSG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
. "$VPSG_ROOT/core/common.sh"
. "$VPSG_ROOT/core/inspect.sh"

_docker_match() { local file="$1" proto="$2" port="$3"; awk -F'\t' -v p="$proto" -v n="$port" '$2==p && $4==n {print $1 "@" $3 "->" $5 "/" $2}' "$file" 2>/dev/null | paste -sd, -; }

service_hint() {
  case "$1" in
    20|21) echo "FTP";; 22) echo "SSH";; 23) echo "Telnet";; 25|465|587) echo "Mail/SMTP";; 53) echo "DNS";;
    80|443|8080|8443) echo "Web";; 111|2049) echo "NFS/RPC";; 3306) echo "MySQL";; 5432) echo "PostgreSQL";; 6379) echo "Redis";;
    27017) echo "MongoDB";; 9200|9300) echo "Elasticsearch";; 2375|2376) echo "Docker API";; 11211) echo "Memcached";;
    3389) echo "RDP";; 5900|5901) echo "VNC";; 9090) echo "Admin/metrics";; 9100) echo "Node exporter";; *) echo "Unknown";;
  esac
}

risk_for_listener() {
  local port="$1" scope="$2" fw="$3" docker="${4:-}"
  [[ "$scope" == "loopback" ]] && { echo "LOW|仅本机监听"; return; }
  case "$port" in
    23|2375|6379|11211|27017|9200|9300) echo "CRITICAL|常见敏感服务不应直接暴露公网"; return;;
    3306|5432|111|2049|5900|5901) echo "HIGH|数据库/管理类端口通常应限制来源"; return;;
    22) [[ "$fw" == "allow" || "$fw" == "default" ]] && echo "MEDIUM|SSH 是必要管理入口，请确保密钥认证和防爆破" || echo "LOW|SSH 受防火墙限制"; return;;
    80|443) echo "LOW|常见 Web 服务端口"; return;;
    8080|8443|9090|9100) echo "MEDIUM|可能是管理面板或监控端口，请确认是否需要公网访问"; return;;
  esac
  if [[ "$scope" == "wildcard" && -n "$docker" ]]; then echo "MEDIUM|Docker 已发布到外部接口";
  elif [[ "$scope" == "wildcard" ]]; then echo "MEDIUM|监听所有接口，请确认这是预期行为";
  else echo "INFO|绑定到特定/私有地址"; fi
}

scan() {
  have ss || { error "Exposure Analyzer 需要 iproute2/ss"; return 20; }
  local tmp listeners docker proto addr port scope process fw dm owner risk reason score=100 ccrit=0 chigh=0 cmed=0
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN; listeners="$tmp/listeners"; docker="$tmp/docker"
  inspect_listeners > "$listeners" || true; inspect_docker_ports > "$docker" || true
  [[ -s "$listeners" ]] || { echo "未检测到监听端口。"; return 0; }
  printf '%-6s %-5s %-9s %-9s %-13s %-12s %-12s %s\n' "PORT" "PROTO" "RISK" "SCOPE" "FIREWALL" "SERVICE" "DOCKER" "REASON"
  printf '%s\n' "-----------------------------------------------------------------------------------------------------------------------------"
  while IFS=$'\t' read -r proto addr port scope process; do
    fw="$(inspect_ufw_port_policy "$port" "$proto")"; dm="$(_docker_match "$docker" "$proto" "$port")"; IFS='|' read -r risk reason <<<"$(risk_for_listener "$port" "$scope" "$fw" "$dm")"
    case "$risk" in CRITICAL) ccrit=$((ccrit+1)); score=$((score-25));; HIGH) chigh=$((chigh+1)); score=$((score-15));; MEDIUM) cmed=$((cmed+1)); score=$((score-5));; esac
    [[ $score -lt 0 ]] && score=0
    printf '%-6s %-5s %-9s %-9s %-13s %-12s %-12s %s\n' "$port" "$proto" "$risk" "$scope" "$fw" "$(service_hint "$port")" "${dm:-no}" "$reason"
  done < "$listeners"
  echo; printf '暴露面风险概览: score=%d/100  CRITICAL=%d HIGH=%d MEDIUM=%d\n' "$score" "$ccrit" "$chigh" "$cmed"
  echo "注意：这是本机视角。云安全组、NAT、上游防火墙仍会影响真实互联网可达性。"
  echo "查看某个端口为什么被标记: vpsg exposure explain <port>"
}

explain() {
  local port="${1:-}"; valid_port "$port" || { error "用法: vpsg exposure explain <port>"; return 64; }
  local tmp listeners docker found=0 proto addr p scope process fw dm risk reason
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN; listeners="$tmp/listeners"; docker="$tmp/docker"
  inspect_listeners > "$listeners" || true; inspect_docker_ports > "$docker" || true
  echo "端口 $port — $(service_hint "$port")"; echo
  while IFS=$'\t' read -r proto addr p scope process; do
    [[ "$p" == "$port" ]] || continue; found=1; fw="$(inspect_ufw_port_policy "$port" "$proto")"; dm="$(_docker_match "$docker" "$proto" "$port")"; IFS='|' read -r risk reason <<<"$(risk_for_listener "$port" "$scope" "$fw" "$dm")"
    printf '风险: %s\n原因: %s\n监听: %s/%s @ %s (%s)\n进程: %s\nUFW: %s\n' "$risk" "$reason" "$port" "$proto" "$addr" "$scope" "$process" "$fw"
    [[ -z "$dm" ]] || printf 'Docker: %s\n' "$dm"
    echo; case "$risk" in CRITICAL|HIGH) echo "建议：如果不是明确需要公网访问，请改为 127.0.0.1/私网绑定，或用防火墙限制可信来源。";; MEDIUM) echo "建议：确认该端口属于预期服务，并限制不必要的公网来源。";; *) echo "建议：保持最小暴露原则，并定期运行 vpsg drift scan。";; esac
  done < "$listeners"
  (( found == 1 )) || { warn "当前没有检测到端口 $port 的监听"; return 10; }
}

json() {
  have ss || { error "Exposure Analyzer 需要 ss"; return 20; }
  local tmp first=1 proto addr port scope process fw dm risk reason
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN; inspect_listeners > "$tmp/l" || true; inspect_docker_ports > "$tmp/d" || true
  printf '{"listeners":['
  while IFS=$'\t' read -r proto addr port scope process; do
    (( first == 1 )) || printf ','; first=0; fw="$(inspect_ufw_port_policy "$port" "$proto")"; dm="$(_docker_match "$tmp/d" "$proto" "$port")"; IFS='|' read -r risk reason <<<"$(risk_for_listener "$port" "$scope" "$fw" "$dm")"
    for v in addr process reason dm; do printf -v "$v" '%s' "${!v//\\/\\\\}"; printf -v "$v" '%s' "${!v//\"/\\\"}"; done
    printf '{"proto":"%s","address":"%s","port":%s,"scope":"%s","firewall":"%s","risk":"%s","service":"%s","docker":"%s","reason":"%s","process":"%s"}' "$proto" "$addr" "$port" "$scope" "$fw" "$risk" "$(service_hint "$port")" "$dm" "$reason" "$process"
  done < "$tmp/l"
  printf ']}\n'
}

action="${1:-scan}"; shift || true
case "$action" in status|scan|check) scan;; explain) explain "$@";; json) json;; *) error "exposure 支持: scan|explain <port>|json"; exit 64;; esac
