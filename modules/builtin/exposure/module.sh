#!/usr/bin/env bash
set -uo pipefail
VPSG_ROOT="${VPSG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
. "$VPSG_ROOT/core/common.sh"
. "$VPSG_ROOT/core/platform.sh"
. "$VPSG_ROOT/core/inspect.sh"
PROFILE_FILE="$VPSG_ETC_DIR/profile"

profile_get() {
  local p=general
  if [[ -r "$PROFILE_FILE" && ! -L "$PROFILE_FILE" ]]; then
    p="$(head -n 1 "$PROFILE_FILE" 2>/dev/null || true)"
  fi
  case "$p" in general|web|docker-web|database|proxy|custom) printf '%s\n' "$p";; *) warn "服务器 Profile 配置无效，按 general 处理: $PROFILE_FILE"; echo general;; esac
}
profile_set() {
  require_root || return 1
  local p="${1:-}"
  case "$p" in general|web|docker-web|database|proxy|custom) ;; *) error "profile 支持: general|web|docker-web|database|proxy|custom"; return 64;; esac
  ensure_runtime_dirs || return 40; printf '%s\n' "$p" | atomic_write_file "$PROFILE_FILE" 644 || return 40; ok "服务器用途 Profile 已设置为: $p"
}

service_hint() {
  local port process lower
  port="$1"; process="${2:-}"; lower="${process,,}"
  [[ "$lower" == *sshd* ]] && { echo SSH; return; }
  [[ "$lower" == *redis* ]] && { echo Redis; return; }
  [[ "$lower" == *mysqld* || "$lower" == *mariad* ]] && { echo MySQL; return; }
  [[ "$lower" == *postgres* ]] && { echo PostgreSQL; return; }
  [[ "$lower" == *nginx* || "$lower" == *apache* || "$lower" == *caddy* ]] && { echo Web; return; }
  case "$port" in
    20|21) echo FTP;; 22) echo SSH;; 23) echo Telnet;; 25|465|587) echo Mail/SMTP;; 53) echo DNS;;
    80|443|8080|8443) echo Web;; 111|2049) echo NFS/RPC;; 3306) echo MySQL;; 5432) echo PostgreSQL;; 6379) echo Redis;;
    27017) echo MongoDB;; 9200|9300) echo Elasticsearch;; 2375|2376) echo 'Docker API';; 11211) echo Memcached;;
    3389) echo RDP;; 5900|5901) echo VNC;; 9090) echo Admin/metrics;; 9100) echo 'Node exporter';; *) echo Unknown;;
  esac
}

_profile_expected() {
  local profile="$1" service="$2" port="$3" sshp="${4:-}"
  [[ -n "$sshp" && "$port" == "$sshp" ]] && return 0
  case "$profile" in
    web|docker-web|proxy) [[ "$port" == 80 || "$port" == 443 ]] ;;
    database) [[ "$service" =~ ^(MySQL|PostgreSQL)$ ]] ;;
    *) return 1 ;;
  esac
}

risk_for_record() {
  local port="$1" scope="$2" source="$3" fw="$4" service="$5" profile="$6" sshp="$7"
  if [[ "$scope" == loopback ]]; then echo 'LOW|仅本机监听/发布'; return; fi
  case "$service" in
    Telnet|'Docker API'|Redis|Memcached|MongoDB|Elasticsearch)
      [[ "$scope" == private ]] && echo 'HIGH|敏感服务仅建议在可信私网或本机访问' || echo 'CRITICAL|常见敏感服务不应直接暴露到公网接口'; return;;
    MySQL|PostgreSQL|NFS/RPC|VNC|RDP)
      [[ "$scope" == private ]] && echo 'MEDIUM|数据库/管理类服务位于私网接口，请确认来源限制' || echo 'HIGH|数据库/管理类端口通常不应直接暴露公网'; return;;
    SSH) echo 'MEDIUM|SSH 是管理入口，请使用公钥、Fail2Ban 并限制不必要来源'; return;;
  esac
  if _profile_expected "$profile" "$service" "$port" "$sshp"; then echo 'LOW|符合当前服务器用途 Profile 的预期入口'; return; fi
  if [[ "$source" == docker && "$scope" != loopback ]]; then echo 'MEDIUM|Docker 已向宿主机接口发布该端口，请确认这是预期行为'; return; fi
  if [[ "$scope" == wildcard ]]; then echo 'MEDIUM|监听所有接口，请确认是否需要公网访问'; return; fi
  if [[ "$scope" == private ]]; then echo 'INFO|仅绑定私有/共享地址'; return; fi
  echo 'MEDIUM|绑定到特定非私有地址，请确认这是预期入口'
}

# source proto address port scope process container container_port firewall service risk reason
_build_records() {
  local listeners="$1" docker="$2" out="$3" seen="$4" profile sshp proto addr port scope process fw dm service risk reason name cport
  profile="$(profile_get)"; sshp="$(ssh_primary_port 2>/dev/null || true)"; : > "$out"; : > "$seen"
  while IFS=$'\t' read -r proto addr port scope process; do
    [[ -n "$port" ]] || continue
    fw="$(inspect_ufw_port_policy "$port" "$proto")"
    dm="$(awk -F'\t' -v p="$proto" -v n="$port" '$2==p && $4==n {printf "%s@%s->%s,",$1,$3,$5}' "$docker" 2>/dev/null | sed 's/,$//')"
    service="$(service_hint "$port" "$process")"; IFS='|' read -r risk reason <<<"$(risk_for_record "$port" "$scope" host "$fw" "$service" "$profile" "$sshp")"
    printf 'host\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$proto" "$addr" "$port" "$scope" "$process" "${dm:--}" - "$fw" "$service" "$risk" "$reason" >> "$out"
    printf '%s|%s|%s\n' "$proto" "$addr" "$port" >> "$seen"
  done < "$listeners"
  while IFS=$'\t' read -r name proto addr port cport scope; do
    [[ -n "$port" ]] || continue
    grep -Fqx "${proto}|${addr}|${port}" "$seen" 2>/dev/null && continue
    fw="$(inspect_ufw_port_policy "$port" "$proto")"; service="$(service_hint "${cport:-$port}" "docker:$name")"; IFS='|' read -r risk reason <<<"$(risk_for_record "$port" "$scope" docker "$fw" "$service" "$profile" "$sshp")"
    printf 'docker\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$proto" "$addr" "$port" "$scope" docker-publish "${name:--}" "${cport:--}" "$fw" "$service" "$risk" "$reason" >> "$out"
  done < "$docker"
  LC_ALL=C sort -t $'\t' -k4,4n -k2,2 -k3,3 -o "$out" "$out"
}

_collect() {
  local tmp="$1" dvis=absent
  inspect_listeners > "$tmp/listeners" || return 20
  dvis="$(inspect_docker_visibility 2>/dev/null || true)"
  case "$dvis" in accessible) inspect_docker_ports > "$tmp/docker" || { : > "$tmp/docker"; dvis=restricted; };; *) : > "$tmp/docker";; esac
  printf '%s\n' "$dvis" > "$tmp/docker.visibility"; _build_records "$tmp/listeners" "$tmp/docker" "$tmp/records" "$tmp/seen"
}

scan() (
  set -uo pipefail
  have ss || { error "Exposure Analyzer 需要 iproute2/ss"; return 20; }
  local tmp dvis profile source proto addr port scope process container cport fw service risk reason ccrit=0 chigh=0 cmed=0
  tmp="$(mktemp -d)" || return 40; trap 'rm -rf -- "$tmp"' EXIT; _collect "$tmp" || return $?
  dvis="$(cat "$tmp/docker.visibility")"; profile="$(profile_get)"
  echo "VPS Guard Exposure Analyzer"; echo "Profile: $profile"; echo "Docker visibility: $dvis"
  [[ "$dvis" != restricted ]] || warn "Docker 已安装但当前权限无法访问 daemon。请使用 sudo vpsg exposure scan，避免漏掉 published ports。"
  echo
  [[ -s "$tmp/records" ]] || { echo "未检测到监听或 Docker 发布端口。"; return 0; }
  printf '%-6s %-5s %-9s %-9s %-8s %-10s %-14s %-15s %s\n' PORT PROTO RISK SCOPE SOURCE FW SERVICE OWNER REASON
  printf '%s\n' '----------------------------------------------------------------------------------------------------------------------------'
  while IFS=$'\t' read -r source proto addr port scope process container cport fw service risk reason; do
    case "$risk" in CRITICAL) ccrit=$((ccrit+1));; HIGH) chigh=$((chigh+1));; MEDIUM) cmed=$((cmed+1));; esac
    [[ "$container" == - ]] && container=""; printf '%-6s %-5s %-9s %-9s %-8s %-10s %-14s %-15s %s\n' "$port" "$proto" "$risk" "$scope" "$source" "$fw" "$service" "${container:-host}" "$reason"
  done < "$tmp/records"
  echo; printf '总结: CRITICAL=%d HIGH=%d MEDIUM=%d\n' "$ccrit" "$chigh" "$cmed"
  echo "说明：这是宿主机暴露指标，不等于云安全组/NAT 后互联网一定可达。Docker published ports 不能仅凭普通 UFW INPUT 规则断言已被阻止。"
)

_recommend() {
  local service="$1" scope="$2" source="$3" port="$4"
  case "$service" in
    'Docker API') echo "不要把 Docker daemon API 直接暴露公网；优先使用本机 Unix socket/SSH context，确需 TCP 时使用 TLS 和严格来源控制。";;
    Redis|Memcached|MongoDB|Elasticsearch|MySQL|PostgreSQL) echo "优先绑定 loopback/私网，并在应用和上游防火墙层限制来源；不要把数据库/缓存直接作为公网入口。";;
    Telnet) echo "停用 Telnet，改用 SSH。";;
    SSH) echo "使用公钥认证、Fail2Ban；如条件允许在云安全组限制管理来源。";;
    Web) echo "如果这是预期 Web 入口，使用 TLS、及时更新反向代理/应用，并确认只发布必要端口。";;
    *) [[ "$scope" == wildcard ]] && echo "确认服务是否真的需要监听所有接口；不需要时绑定 loopback/私网。" || echo "确认该端口与服务器用途一致。";;
  esac
  [[ "$source" != docker ]] || echo "Docker 场景建议同时检查容器 publish 配置和 DOCKER-USER/上游防火墙，不要只依赖 ufw status。"
  echo "查看端口: ss -lntup | grep ':${port} '"
}

explain() (
  local wanted="${1:-}" tmp source proto addr port scope process container cport fw service risk reason found=0
  valid_port "$wanted" || { error "用法: vpsg exposure explain <port>"; return 64; }
  have ss || return 20; tmp="$(mktemp -d)" || return 40; trap 'rm -rf -- "$tmp"' EXIT; _collect "$tmp" || return $?
  while IFS=$'\t' read -r source proto addr port scope process container cport fw service risk reason; do
    [[ "$port" == "$wanted" ]] || continue; found=1
    echo "${port}/${proto} — $risk"; echo "来源: $source"; echo "绑定: $addr ($scope)"; echo "服务推测: $service"; echo "UFW host policy: $fw"; [[ "$container" == - ]] || echo "Docker: $container -> ${cport}/${proto}"; echo "为什么关注: $reason"; echo "建议:"; _recommend "$service" "$scope" "$source" "$port"; echo
  done < "$tmp/records"
  ((found)) || { echo "没有检测到端口 $wanted 的监听/发布记录。"; return 20; }
)

_json_escape() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"; printf '%s' "$s"; }
json() (
  local tmp dvis first=1 source proto addr port scope process container cport fw service risk reason
  have ss || return 20; tmp="$(mktemp -d)" || return 40; trap 'rm -rf -- "$tmp"' EXIT; _collect "$tmp" || return $?
  dvis="$(cat "$tmp/docker.visibility")"; printf '{"profile":"%s","docker_visibility":"%s","records":[' "$(_json_escape "$(profile_get)")" "$(_json_escape "$dvis")"
  while IFS=$'\t' read -r source proto addr port scope process container cport fw service risk reason; do
    ((first)) || printf ','; first=0
    printf '{"source":"%s","proto":"%s","address":"%s","port":%s,"scope":"%s","process":"%s","container":"%s","container_port":"%s","firewall":"%s","service":"%s","risk":"%s","reason":"%s"}' \
      "$(_json_escape "$source")" "$(_json_escape "$proto")" "$(_json_escape "$addr")" "$port" "$(_json_escape "$scope")" "$(_json_escape "$process")" "$(_json_escape "$container")" "$(_json_escape "$cport")" "$(_json_escape "$fw")" "$(_json_escape "$service")" "$(_json_escape "$risk")" "$(_json_escape "$reason")"
  done < "$tmp/records"
  printf ']}\n'
)

profile_cmd() { local sub="${1:-show}"; shift || true; case "$sub" in show|status) profile_get;; set) profile_set "$@";; *) error "exposure profile: show|set <general|web|docker-web|database|proxy|custom>"; return 64;; esac; }
action="${1:-scan}"; shift || true
case "$action" in scan|status|check) scan;; explain) explain "$@";; json) json;; profile) profile_cmd "$@";; *) error "exposure 支持: scan|explain <port>|json|profile show|set <type>"; exit 64;; esac
