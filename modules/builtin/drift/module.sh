#!/usr/bin/env bash
set -uo pipefail
VPSG_ROOT="${VPSG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
. "$VPSG_ROOT/core/common.sh"
. "$VPSG_ROOT/core/inspect.sh"
BASE_DIR="$VPSG_STATE_DIR/baselines"; REPORT_DIR="$VPSG_STATE_DIR/drift-reports"
risk_for() { case "$1" in listeners.tsv|docker-ports.tsv|authorized-keys.tsv|sudo.tsv|ssh.txt|cron.tsv) echo HIGH;; users.tsv|services.txt|docker.tsv|firewall.txt|sysctl.txt) echo MEDIUM;; *) echo INFO;; esac; }
label_for() { case "$1" in listeners.tsv) echo "监听端口";; docker-ports.tsv) echo "Docker 公布端口";; authorized-keys.tsv) echo "SSH authorized_keys";; sudo.tsv) echo "sudo 权限";; users.tsv) echo "用户账户";; ssh.txt) echo "SSH 有效配置";; firewall.txt) echo "防火墙";; services.txt) echo "开机服务";; docker.tsv) echo "Docker 容器";; cron.tsv) echo "计划任务";; sysctl.txt) echo "安全 sysctl";; *) echo "$1";; esac; }
why_for() { case "$1" in listeners.tsv) echo "新增监听端口可能意味着新的公网入口";; docker-ports.tsv) echo "Docker 端口发布可能绕过你对普通进程监听的预期";; authorized-keys.tsv) echo "SSH key 变化可能增加远程登录权限";; sudo.tsv) echo "sudo 变化会影响管理员权限";; ssh.txt) echo "SSH 配置变化会影响远程登录安全";; cron.tsv) echo "计划任务可被用于持久化执行程序";; users.tsv) echo "新增/删除用户可能影响访问控制";; services.txt) echo "新开机服务会扩大长期运行面";; firewall.txt) echo "防火墙变化会直接改变网络访问策略";; *) echo "该安全状态与基线不同";; esac; }
print_diff() { local f="$1" b="$2" a="$3" n=0 line; if [[ "$f" =~ ^(listeners.tsv|docker-ports.tsv|users.tsv|sudo.tsv|authorized-keys.tsv|services.txt|docker.tsv|cron.tsv)$ ]]; then while IFS= read -r line; do n=$((n+1)); ((n<=8)) && printf '    + %s\n' "$line"; done < <(comm -13 <(sort "$b") <(sort "$a")); while IFS= read -r line; do n=$((n+1)); ((n<=8)) && printf '    - %s\n' "$line"; done < <(comm -23 <(sort "$b") <(sort "$a")); ((n>8)) && echo "    ... 另有 $((n-8)) 条"; else echo "    内容发生变化"; fi; }
scan() {
  require_root || return 1; local name="default" strict=0; while (($#)); do case "$1" in --strict) strict=1; shift;; *) name="$1"; shift;; esac; done
  [[ "$name" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || return 64; local base="$BASE_DIR/$name"; [[ -d "$base" ]] || { error "基线不存在: $name。先运行 sudo vpsg baseline create $name"; return 20; }
  local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN; snapshot_capture "$tmp"
  local files=(listeners.tsv docker-ports.tsv authorized-keys.tsv sudo.tsv users.tsv ssh.txt firewall.txt services.txt docker.tsv cron.tsv sysctl.txt) f changes=0 high=0 medium=0 info_n=0 risk before after report
  ensure_runtime_dirs; mkdir -p "$REPORT_DIR"; report="$REPORT_DIR/$(date +%Y%m%d-%H%M%S)-${name}.log"
  { echo "Baseline & Drift: $name"; echo "基线时间: $(awk -F= '$1=="created" {print substr($0,index($0,"=")+1)}' "$base/manifest" 2>/dev/null)"; echo "扫描时间: $(date -Is)"; echo
    for f in "${files[@]}"; do before="$base/$f"; after="$tmp/$f"; [[ -e "$before" ]] || before=/dev/null; [[ -e "$after" ]] || after=/dev/null; if ! cmp -s "$before" "$after"; then changes=$((changes+1)); risk="$(risk_for "$f")"; case "$risk" in HIGH) high=$((high+1));; MEDIUM) medium=$((medium+1));; *) info_n=$((info_n+1));; esac; printf '[%s] %s\n' "$risk" "$(label_for "$f")"; echo "    为什么关注: $(why_for "$f")"; print_diff "$f" "$before" "$after"; echo; fi; done
    if ((changes==0)); then echo "[OK] 未检测到配置漂移。"; else printf '总结: %d 个区域变化 — HIGH=%d MEDIUM=%d INFO=%d\n' "$changes" "$high" "$medium" "$info_n"; echo "如果这些变化都是你做的并确认可信：sudo vpsg baseline create $name --force"; echo "如果不是你做的，优先检查 SSH key、sudo、监听端口和 cron。"; fi
  } | tee "$report"
  (( strict == 1 && changes > 0 )) && return 3; return 0
}
history() { [[ -d "$REPORT_DIR" ]] || { echo "暂无 Drift 报告。"; return 0; }; find "$REPORT_DIR" -maxdepth 1 -type f -printf '%f\n' | sort -r | head -n "${1:-20}"; }
show() { local f="$REPORT_DIR/${1:-}"; [[ -f "$f" ]] || { error "报告不存在"; return 20; }; cat "$f"; }
action="${1:-scan}"; shift || true
case "$action" in scan|status|check) scan "$@";; history) history "$@";; show) show "$@";; *) error "drift 支持: scan [baseline] [--strict]|history|show <report>"; exit 64;; esac
