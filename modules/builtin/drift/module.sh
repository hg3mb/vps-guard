#!/usr/bin/env bash
set -uo pipefail
VPSG_ROOT="${VPSG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
. "$VPSG_ROOT/core/common.sh"
. "$VPSG_ROOT/core/inspect.sh"
BASE_DIR="$VPSG_STATE_DIR/baselines"

risk_for() {
  case "$1" in
    listeners.tsv|docker-ports.tsv|authorized-keys.tsv|sudo.tsv|ssh.txt|cron.tsv) echo HIGH ;;
    users.tsv|services.txt|docker.tsv|firewall.txt|sysctl.txt) echo MEDIUM ;;
    *) echo INFO ;;
  esac
}

print_added_removed() {
  local file="$1" before="$2" after="$3" max="${4:-8}" count=0 line
  if [[ "$file" == "listeners.tsv" || "$file" == "docker-ports.tsv" || "$file" == "users.tsv" || "$file" == "sudo.tsv" || "$file" == "authorized-keys.tsv" || "$file" == "services.txt" || "$file" == "docker.tsv" || "$file" == "cron.tsv" ]]; then
    while IFS= read -r line; do
      ((count++)); (( count <= max )) && printf '    + %s\n' "$line"
    done < <(comm -13 <(sort "$before") <(sort "$after"))
    while IFS= read -r line; do
      ((count++)); (( count <= max )) && printf '    - %s\n' "$line"
    done < <(comm -23 <(sort "$before") <(sort "$after"))
    (( count > max )) && printf '    ... 另有 %d 条变化\n' "$((count-max))"
  else
    echo "    内容发生变化（使用 diff 命令可查看完整差异）"
  fi
}

scan() {
  require_root || return 1
  local name="default" strict=0
  while (($#)); do
    case "$1" in --strict) strict=1; shift;; *) name="$1"; shift;; esac
  done
  [[ "$name" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || { error "无效基线名称"; return 64; }
  local base="$BASE_DIR/$name"; [[ -d "$base" ]] || { error "基线不存在: $name。先运行 sudo vpsg baseline create $name"; return 20; }
  local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  snapshot_capture "$tmp"
  local files=(listeners.tsv docker-ports.tsv authorized-keys.tsv sudo.tsv users.tsv ssh.txt firewall.txt services.txt docker.tsv cron.tsv sysctl.txt)
  local f changes=0 high=0 medium=0 info_n=0 risk before after
  echo "Baseline & Drift: $name"
  echo "基线时间: $(awk -F= '$1=="created" {print substr($0,index($0,"=")+1)}' "$base/manifest" 2>/dev/null)"
  echo
  for f in "${files[@]}"; do
    before="$base/$f"; after="$tmp/$f"
    [[ -e "$before" ]] || before=/dev/null
    [[ -e "$after" ]] || after=/dev/null
    if ! cmp -s "$before" "$after"; then
      changes=$((changes+1)); risk="$(risk_for "$f")"
      case "$risk" in HIGH) high=$((high+1));; MEDIUM) medium=$((medium+1));; *) info_n=$((info_n+1));; esac
      printf '[%s] %s\n' "$risk" "$f"
      print_added_removed "$f" "$before" "$after"
    fi
  done
  echo
  if (( changes == 0 )); then
    ok "未检测到配置漂移。"
    return 0
  fi
  printf '检测到 %d 个配置区域发生变化：HIGH=%d MEDIUM=%d INFO=%d\n' "$changes" "$high" "$medium" "$info_n"
  echo "确认这些变化可信后，可执行: sudo vpsg baseline create $name --force"
  (( strict == 1 )) && return 3
  return 0
}

action="${1:-scan}"; shift || true
case "$action" in
  scan|status|check) scan "$@" ;;
  *) error "drift 支持: scan [baseline] [--strict]"; exit 64 ;;
esac
