#!/usr/bin/env bash
set -uo pipefail
VPSG_ROOT="${VPSG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
. "$VPSG_ROOT/core/common.sh"
. "$VPSG_ROOT/core/inspect.sh"
BASE_DIR="$VPSG_STATE_DIR/baselines"
REPORT_DIR="$VPSG_STATE_DIR/drift-reports"
DRIFT_CRITICAL=0; DRIFT_HIGH=0; DRIFT_MEDIUM=0; DRIFT_INFO=0; DRIFT_CHANGES=0
_valid_name() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; }
_valid_report_id() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$ ]]; }

_emit() {
  local sev="$1" title="$2" why="$3" detail="${4:-}"
  DRIFT_CHANGES=$((DRIFT_CHANGES+1))
  case "$sev" in CRITICAL) DRIFT_CRITICAL=$((DRIFT_CRITICAL+1));; HIGH) DRIFT_HIGH=$((DRIFT_HIGH+1));; MEDIUM) DRIFT_MEDIUM=$((DRIFT_MEDIUM+1));; *) DRIFT_INFO=$((DRIFT_INFO+1)); sev=INFO;; esac
  printf '[%s] %s\n    为什么关注: %s\n' "$sev" "$title" "$why"; [[ -z "$detail" ]] || printf '    %s\n' "$detail"; echo
}

_port_semantic_risk() {
  local port="$1" scope="$2"
  [[ "$scope" == loopback ]] && { echo INFO; return; }
  case "$port" in
    23|2375|6379|11211|27017|9200|9300) [[ "$scope" == private ]] && echo HIGH || echo CRITICAL;;
    3306|5432|111|2049|5900|5901|3389) [[ "$scope" == private ]] && echo MEDIUM || echo HIGH;;
    22) echo MEDIUM;; 80|443) echo INFO;; 8080|8443|9090|9100) echo MEDIUM;;
    *) [[ "$scope" == wildcard || "$scope" == specific ]] && echo MEDIUM || echo INFO;;
  esac
}

_diff_listeners() {
  local before="$1" after="$2" line proto addr port scope process sev
  while IFS= read -r line; do [[ -n "$line" ]] || continue; IFS=$'\t' read -r proto addr port scope process <<<"$line"; sev="$(_port_semantic_risk "$port" "$scope")"; _emit "$sev" "新增监听端口 ${port}/${proto}" "新增监听服务可能扩大服务器攻击面。" "${addr}:${port} scope=${scope} process=${process}"; done < <(comm -13 <(LC_ALL=C sort "$before") <(LC_ALL=C sort "$after"))
  while IFS= read -r line; do [[ -n "$line" ]] || continue; IFS=$'\t' read -r proto addr port scope process <<<"$line"; _emit INFO "监听端口消失 ${port}/${proto}" "服务停止或绑定方式变化也属于需要知道的服务器变化。" "${addr}:${port} scope=${scope} process=${process}"; done < <(comm -23 <(LC_ALL=C sort "$before") <(LC_ALL=C sort "$after"))
}

_diff_docker_ports() {
  local before="$1" after="$2" line name proto addr port cport scope sev
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    IFS=$'\t' read -r name proto addr port cport scope <<<"$line"
    # For Docker publishes, the container port is the better service semantic
    # signal (e.g. 13306->3306 is still a database exposure).
    sev="$(_port_semantic_risk "${cport:-$port}" "$scope")"
    [[ "$sev" == INFO && "$scope" != loopback ]] && sev=MEDIUM
    _emit "$sev" "Docker 新增发布端口 ${port}/${proto}" "Docker publish 会改变宿主机网络暴露，不能只看普通进程监听。" "container=${name} ${addr}:${port}->${cport}/${proto} scope=${scope}"
  done < <(comm -13 <(LC_ALL=C sort "$before") <(LC_ALL=C sort "$after"))
  while IFS= read -r line; do [[ -n "$line" ]] || continue; IFS=$'\t' read -r name proto addr port cport scope <<<"$line"; _emit INFO "Docker 发布端口移除 ${port}/${proto}" "容器网络暴露发生变化。" "container=${name} ${addr}:${port}->${cport}/${proto}"; done < <(comm -23 <(LC_ALL=C sort "$before") <(LC_ALL=C sort "$after"))
}

_diff_simple_lines() {
  local before="$1" after="$2" add_sev="$3" del_sev="$4" title="$5" why="$6" line
  while IFS= read -r line; do [[ -n "$line" ]] && _emit "$add_sev" "新增${title}" "$why" "$line"; done < <(comm -13 <(LC_ALL=C sort "$before") <(LC_ALL=C sort "$after"))
  while IFS= read -r line; do [[ -n "$line" ]] && _emit "$del_sev" "移除${title}" "$why" "$line"; done < <(comm -23 <(LC_ALL=C sort "$before") <(LC_ALL=C sort "$after"))
}

_diff_authorized_keys() {
  local before="$1" after="$2" path oldrow newrow oldcount newcount
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue; oldrow="$(awk -F'\t' -v p="$path" '$1==p {print; exit}' "$before")"; newrow="$(awk -F'\t' -v p="$path" '$1==p {print; exit}' "$after")"
    [[ "$oldrow" == "$newrow" ]] && continue
    oldcount="$(cut -f2 <<<"$oldrow")"; newcount="$(cut -f2 <<<"$newrow")"
    _emit HIGH "SSH authorized_keys 变化: $path" "SSH key 变化可能增加或移除远程登录权限。" "keys: ${oldcount:-0} -> ${newcount:-0}"
  done < <(cat "$before" "$after" 2>/dev/null | cut -f1 | LC_ALL=C sort -u)
}

_diff_collection() {
  local before="$1" after="$2" section old new
  while IFS= read -r section; do
    [[ -n "$section" ]] || continue; old="$(awk -F'\t' -v s="$section" '$1==s {print $2}' "$before" | tail -1)"; new="$(awk -F'\t' -v s="$section" '$1==s {print $2}' "$after" | tail -1)"; [[ "$old" == "$new" ]] && continue
    if [[ "$old" == ok && "$new" != ok ]]; then _emit MEDIUM "采集覆盖下降: $section" "扫描器无法继续完整观察这一安全区域；'没有发现问题' 此时并不等于安全。" "before=$old now=${new:-missing}"
    elif [[ "$old" != ok && "$new" == ok ]]; then _emit INFO "采集覆盖恢复: $section" "该安全区域现在重新能够被完整检查。" "before=${old:-missing} now=$new"
    else _emit MEDIUM "采集状态变化: $section" "安全扫描覆盖状态发生变化。" "before=${old:-missing} now=${new:-missing}"; fi
  done < <(cat "$before" "$after" 2>/dev/null | cut -f1 | LC_ALL=C sort -u)
}

_compare_snapshots() {
  local base="$1" now="$2"
  _diff_collection "$base/collection.tsv" "$now/collection.tsv"
  _diff_listeners "$base/listeners.tsv" "$now/listeners.tsv"
  _diff_docker_ports "$base/docker-ports.tsv" "$now/docker-ports.tsv"
  _diff_authorized_keys "$base/authorized-keys.tsv" "$now/authorized-keys.tsv"
  _diff_simple_lines "$base/sudo.tsv" "$now/sudo.tsv" HIGH HIGH ' sudo 权限记录' 'sudo 变化会影响管理员权限。'
  _diff_simple_lines "$base/users.tsv" "$now/users.tsv" MEDIUM INFO ' 可登录用户' '用户账户变化会影响访问控制。'
  _diff_simple_lines "$base/services.txt" "$now/services.txt" MEDIUM INFO ' 开机服务' '新的长期运行服务会扩大持久运行面。'
  _diff_simple_lines "$base/cron.tsv" "$now/cron.tsv" HIGH INFO ' cron 记录' '计划任务可用于长期自动执行程序。'
  _diff_simple_lines "$base/docker.tsv" "$now/docker.tsv" INFO INFO ' Docker 容器状态' '容器集合或运行状态发生变化。'
  cmp -s "$base/ssh.txt" "$now/ssh.txt" || _emit HIGH 'SSH 有效配置变化' 'SSH 实际解析后的配置会直接影响远程访问安全。' '运行 vpsg ssh status 查看当前设置。'
  cmp -s "$base/firewall.txt" "$now/firewall.txt" || _emit MEDIUM '防火墙状态变化' '防火墙变化会直接影响网络访问策略。' '运行 vpsg firewall status 查看当前规则。'
  cmp -s "$base/sysctl.txt" "$now/sysctl.txt" || _emit MEDIUM '安全 sysctl 变化' '内核网络与信息暴露相关参数发生变化。'
}

scan() {
  require_root || return 1
  local name=default strict=0 base id rdir snap report rc=0
  while (($#)); do case "$1" in --strict) strict=1; shift;; *) name="$1"; shift;; esac; done
  _valid_name "$name" || return 64; base="$BASE_DIR/$name"; [[ -d "$base" ]] || { error "基线不存在: $name。先运行 sudo vpsg baseline create $name"; return 20; }
  snapshot_verify "$base" || { error "拒绝比较：基线完整性验证失败或属于旧 schema。先运行 sudo vpsg baseline verify $name。"; return 50; }
  ensure_runtime_dirs || return 40; mkdir -p "$REPORT_DIR" || return 40; chmod 700 "$REPORT_DIR" 2>/dev/null || true
  id="$(date +%Y%m%d-%H%M%S)-${name}-$$"; rdir="$REPORT_DIR/$id"; mkdir -p "$rdir/snapshot" || return 40; snap="$rdir/snapshot"
  if ! snapshot_capture "$snap" || ! snapshot_seal "$snap" || ! snapshot_verify "$snap"; then safe_rm_rf_within "$rdir" "$REPORT_DIR" 2>/dev/null || true; error "当前快照采集/封存失败"; return 40; fi
  cat > "$rdir/meta" <<EOF_META
id=$id
baseline=$name
created=$(date -Is)
EOF_META
  report="$rdir/report.txt"; DRIFT_CRITICAL=0; DRIFT_HIGH=0; DRIFT_MEDIUM=0; DRIFT_INFO=0; DRIFT_CHANGES=0
  {
    echo 'VPS Guard Baseline & Drift'; echo "Baseline: $name"; echo "Scan: $(date -Is)"; echo
    _compare_snapshots "$base" "$snap"
    if ((DRIFT_CHANGES==0)); then echo '[OK] 未检测到配置漂移。'
    else printf '总结: %d 项语义变化 — CRITICAL=%d HIGH=%d MEDIUM=%d INFO=%d\n' "$DRIFT_CHANGES" "$DRIFT_CRITICAL" "$DRIFT_HIGH" "$DRIFT_MEDIUM" "$DRIFT_INFO"; echo "确认变化可信后: sudo vpsg drift accept $id"; echo '若不是你做的，优先检查 SSH keys、sudo、监听端口、Docker publish 和 cron。'; fi
  } > "$report"
  cat > "$rdir/summary.env" <<EOF_SUMMARY
changes=$DRIFT_CHANGES
critical=$DRIFT_CRITICAL
high=$DRIFT_HIGH
medium=$DRIFT_MEDIUM
info=$DRIFT_INFO
EOF_SUMMARY
  chmod 600 "$rdir/meta" "$rdir/summary.env" "$report" 2>/dev/null || true; cat "$report"
  log_event INFO "drift scan id=$id baseline=$name changes=$DRIFT_CHANGES critical=$DRIFT_CRITICAL high=$DRIFT_HIGH medium=$DRIFT_MEDIUM"
  ((strict==1 && DRIFT_CHANGES>0)) && rc=3; return "$rc"
}

history() { local limit="${1:-20}" d; [[ "$limit" =~ ^[0-9]+$ ]] || limit=20; [[ -d "$REPORT_DIR" ]] || { echo '暂无 Drift 报告。'; return 0; }; printf '%-42s %-18s %s\n' REPORT BASELINE CREATED; find "$REPORT_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | LC_ALL=C sort -r | head -n "$limit" | while read -r d; do printf '%-42s %-18s %s\n' "$d" "$(awk -F= '$1=="baseline" {print $2}' "$REPORT_DIR/$d/meta" 2>/dev/null)" "$(awk -F= '$1=="created" {print substr($0,index($0,"=")+1)}' "$REPORT_DIR/$d/meta" 2>/dev/null)"; done; }
show() { local id="${1:-}"; _valid_report_id "$id" || return 64; [[ -r "$REPORT_DIR/$id/report.txt" ]] || { error "报告不存在: $id"; return 20; }; cat "$REPORT_DIR/$id/report.txt"; }

accept() {
  require_root || return 1
  local id="${1:-}" rdir name snap dest tmp old
  _valid_report_id "$id" || { error "用法: sudo vpsg drift accept <report-id>"; return 64; }; rdir="$REPORT_DIR/$id"; snap="$rdir/snapshot"; [[ -d "$snap" && -r "$rdir/meta" ]] || return 20
  snapshot_verify "$snap" || { error "报告快照完整性验证失败，拒绝接受"; return 50; }
  name="$(awk -F= '$1=="baseline" {print $2}' "$rdir/meta" | tail -1)"; _valid_name "$name" || return 50
  echo "将已经审核的报告快照 $id 设为基线 '$name'。不会重新采集当前系统。"; confirm "确认这些变化全部可信？" || return 10
  mkdir -p "$BASE_DIR" || return 40; dest="$BASE_DIR/$name"; tmp="$(mktemp -d "$BASE_DIR/.${name}.accept.XXXXXX")" || return 40
  cp -a "$snap"/. "$tmp"/ || { safe_rm_rf_within "$tmp" "$BASE_DIR" 2>/dev/null || true; return 40; }
  if ! sed -i '/^name=/d;/^accepted_from=/d' "$tmp/manifest"; then safe_rm_rf_within "$tmp" "$BASE_DIR" 2>/dev/null || true; return 40; fi
  if ! printf 'name=%s\naccepted_from=%s\n' "$name" "$id" >> "$tmp/manifest"; then safe_rm_rf_within "$tmp" "$BASE_DIR" 2>/dev/null || true; return 40; fi
  snapshot_seal "$tmp" || { safe_rm_rf_within "$tmp" "$BASE_DIR" 2>/dev/null || true; return 40; }
  snapshot_verify "$tmp" || { safe_rm_rf_within "$tmp" "$BASE_DIR" 2>/dev/null || true; return 50; }
  old="${dest}.old.$$"; safe_rm_rf_within "$old" "$BASE_DIR" 2>/dev/null || true
  if [[ -d "$dest" ]]; then mv -- "$dest" "$old" || { safe_rm_rf_within "$tmp" "$BASE_DIR" 2>/dev/null || true; return 40; }; fi
  if ! mv -- "$tmp" "$dest"; then [[ ! -d "$old" ]] || mv -- "$old" "$dest" 2>/dev/null || true; safe_rm_rf_within "$tmp" "$BASE_DIR" 2>/dev/null || true; return 40; fi
  safe_rm_rf_within "$old" "$BASE_DIR" 2>/dev/null || true; log_event INFO "drift accepted id=$id baseline=$name"; ok "已将审核过的快照设为新基线: $name"
}

action="${1:-scan}"; shift || true; parse_yes_flag "$@"
case "$action" in scan|status|check) scan "$@";; history) history "$@";; show) show "$@";; accept) accept "$@";; *) error "drift 支持: scan [baseline] [--strict]|history|show <report-id>|accept <report-id>"; exit 64;; esac
