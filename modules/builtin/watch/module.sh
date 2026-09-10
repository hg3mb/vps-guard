#!/usr/bin/env bash
set -uo pipefail
VPSG_ROOT="${VPSG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
. "$VPSG_ROOT/core/common.sh"

WATCH_DIR="$VPSG_STATE_DIR/watch"
REPORT_DIR="$WATCH_DIR/reports"
CONF="$VPSG_ETC_DIR/watch.conf"
HOOK="$VPSG_ETC_DIR/watch-notify"
SERVICE="$VPSG_SYSTEMD_DIR/vps-guard-watch.service"
TIMER="$VPSG_SYSTEMD_DIR/vps-guard-watch.timer"

_threshold() {
  local t="MEDIUM"
  [[ -r "$CONF" ]] && t="$(awk -F= '$1=="threshold" {print toupper($2)}' "$CONF" | tail -1)"
  case "$t" in CRITICAL|HIGH|MEDIUM) printf '%s\n' "$t";; *) printf 'MEDIUM\n';; esac
}
_sev_rank() { case "${1:-INFO}" in CRITICAL) echo 4;; HIGH) echo 3;; MEDIUM) echo 2;; LOW) echo 1;; *) echo 0;; esac; }

_report_max_severity() {
  local file="$1" line sev max=INFO rank=0 r
  while IFS= read -r line; do
    sev=""
    [[ "$line" =~ \[(CRITICAL|HIGH|MEDIUM|LOW|INFO)\] ]] && sev="${BASH_REMATCH[1]}"
    if [[ -z "$sev" ]]; then
      sev="$(awk '{for(i=1;i<=NF;i++) if($i ~ /^(CRITICAL|HIGH|MEDIUM|LOW|INFO)$/){print $i; exit}}' <<<"$line")"
    fi
    [[ -n "$sev" ]] || continue
    r="$(_sev_rank "$sev")"; if ((r>rank)); then rank="$r"; max="$sev"; fi
  done < "$file"
  printf '%s\n' "$max"
}

_report_fingerprint() {
  local file="$1"
  # Only risk-bearing lines influence notification de-duplication; timestamps and
  # harmless table decoration must not create a new alert every day.
  awk '/\[(CRITICAL|HIGH|MEDIUM)\]/ || $0 ~ /(^|[[:space:]])(CRITICAL|HIGH|MEDIUM)([[:space:]]|$)/ {print}' "$file" \
    | sed -E 's/[[:space:]]+/ /g' | LC_ALL=C sort | sha256sum | awk '{print $1}'
}

_hook_safe() {
  [[ -f "$HOOK" && ! -L "$HOOK" && -x "$HOOK" ]] || return 1
  local uid mode
  uid="$(stat -c '%u' "$HOOK" 2>/dev/null || echo -1)"; mode="$(stat -c '%a' "$HOOK" 2>/dev/null || echo 777)"
  [[ "$uid" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  local last3="${mode: -3}" g="${mode: -2:1}" o="${mode: -1}"
  (( (10#$g & 2) == 0 && (10#$o & 2) == 0 ))
}

_notify_if_needed() {
  local report="$1" severity="$2" threshold fingerprint old rc=0 severity_rank threshold_rank
  threshold="$(_threshold)"
  severity_rank="$(_sev_rank "$severity")"
  threshold_rank="$(_sev_rank "$threshold")"
  ((severity_rank >= threshold_rank)) || return 0
  [[ "$severity" != INFO && "$severity" != LOW ]] || return 0
  if [[ ! -e "$HOOK" ]]; then return 0; fi
  if ! _hook_safe; then warn "Watch 通知 hook 权限不安全，已拒绝执行: $HOOK"; return 30; fi
  fingerprint="$(_report_fingerprint "$report")"
  old="$(cat "$WATCH_DIR/last-notified.sha256" 2>/dev/null || true)"
  [[ -n "$fingerprint" && "$fingerprint" != "$old" ]] || return 0
  "$HOOK" "$report" "$severity" || rc=$?
  if ((rc==0)); then printf '%s\n' "$fingerprint" | atomic_write_file "$WATCH_DIR/last-notified.sha256" 600 || return 40; log_event INFO "watch notification sent severity=$severity"; return 0; fi
  warn "Watch 通知 hook 执行失败（rc=$rc），不会标记为已通知，下次会重试。"
  return "$rc"
}

_retention() {
  [[ -d "$REPORT_DIR" ]] || return 0
  local count=0 f
  while IFS= read -r f; do
    count=$((count+1)); ((count<=30)) && continue
    if ! safe_rm_rf_within "$f" "$REPORT_DIR" >/dev/null 2>&1; then warn "Watch 无法安全清理旧报告: $f"; fi
  done < <(find "$REPORT_DIR" -mindepth 1 -maxdepth 1 -type f -name 'watch-*.log' -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
}

run_watch() {
  require_root || return 1
  ensure_runtime_dirs || return 40
  mkdir -p "$REPORT_DIR" || return 40; chmod 700 "$WATCH_DIR" "$REPORT_DIR" 2>/dev/null || true
  local stamp out tmp drift_rc=0 exposure_rc=0 severity
  stamp="$(date +%Y%m%d-%H%M%S)"; out="$REPORT_DIR/watch-$stamp.log"; tmp="$(mktemp "$REPORT_DIR/.watch.tmp.XXXXXX")" || return 40
  {
    echo "VPS Guard Watch — $(date -Is)"
    echo
    echo "=== Exposure ==="
    /bin/bash "$VPSG_ROOT/modules/builtin/exposure/module.sh" scan || exposure_rc=$?
    echo
    echo "=== Drift ==="
    if [[ -d "$VPSG_STATE_DIR/baselines/default" ]]; then
      /bin/bash "$VPSG_ROOT/modules/builtin/drift/module.sh" scan default --strict || drift_rc=$?
    else
      echo "尚未创建 default 基线。运行: sudo vpsg baseline create"
    fi
  } > "$tmp" 2>&1
  chmod 600 "$tmp" || { rm -f "$tmp"; return 40; }; mv -f "$tmp" "$out" || { rm -f "$tmp"; return 40; }
  severity="$(_report_max_severity "$out")"
  cat <<EOF_STATE | atomic_write_file "$WATCH_DIR/latest.state" 600 || return 40
report=$out
severity=$severity
exposure_rc=$exposure_rc
drift_rc=$drift_rc
created_epoch=$(date +%s)
EOF_STATE
  _retention
  _notify_if_needed "$out" "$severity" || true
  log_event INFO "watch run report=$out severity=$severity exposure_rc=$exposure_rc drift_rc=$drift_rc"
  printf 'Watch 报告: %s\n最高风险: %s\n' "$out" "$severity"
}

status() {
  local enabled=no active=no
  if have systemctl; then systemctl is-enabled --quiet vps-guard-watch.timer 2>/dev/null && enabled=yes; systemctl is-active --quiet vps-guard-watch.timer 2>/dev/null && active=yes; fi
  printf 'VPS Guard Watch: enabled=%s active=%s threshold=%s\n' "$enabled" "$active" "$(_threshold)"
  if [[ -r "$WATCH_DIR/latest.state" ]]; then
    printf '最近报告: %s\n最高风险: %s\n' "$(awk -F= '$1=="report" {print substr($0,index($0,"=")+1)}' "$WATCH_DIR/latest.state")" "$(awk -F= '$1=="severity" {print $2}' "$WATCH_DIR/latest.state")"
  fi
  [[ ! -e "$HOOK" ]] || { _hook_safe && echo "通知 hook: 已配置且权限安全" || echo "通知 hook: 已配置，但权限不安全（不会执行）"; }
}

_watch_unit_state() {
  local file="$1"
  if [[ ! -e "$file" && ! -L "$file" ]]; then printf 'absent\n'; return 0; fi
  if vpsg_file_is_managed "$file"; then printf 'managed\n'; return 0; fi
  printf 'foreign\n'
}

_watch_units_safe_to_manage() {
  local s t
  s="$(_watch_unit_state "$SERVICE")"; t="$(_watch_unit_state "$TIMER")"
  if [[ "$s" == foreign || "$t" == foreign ]]; then
    error "检测到同名但非 VPS Guard 管理的 systemd unit，拒绝覆盖/删除。"
    [[ "$s" != foreign ]] || error "保留: $SERVICE"
    [[ "$t" != foreign ]] || error "保留: $TIMER"
    return 30
  fi
}

enable_watch() (
  set -uo pipefail
  require_root || return 1
  have systemctl || { error "Watch 需要 systemd"; return 20; }
  ensure_runtime_dirs || return 40
  mkdir -p "$WATCH_DIR" "$REPORT_DIR" "$VPSG_SYSTEMD_DIR" || return 40
  chmod 700 "$WATCH_DIR" "$REPORT_DIR" || return 40
  _watch_units_safe_to_manage || return $?

  local exec_arg state_arg log_arg backup was_enabled=0 was_active=0 rc=0
  exec_arg="$(systemd_quote_arg "$VPSG_ROOT/bin/vpsg")" || return 64
  state_arg="$(systemd_quote_arg "$VPSG_STATE_DIR")" || return 64
  log_arg="$(systemd_quote_arg "$VPSG_LOG_DIR")" || return 64
  backup="$(mktemp -d)" || return 40
  trap 'rm -rf -- "$backup"' EXIT
  [[ -f "$SERVICE" && ! -L "$SERVICE" ]] && cp -a -- "$SERVICE" "$backup/service" || : > "$backup/service.absent"
  [[ -f "$TIMER" && ! -L "$TIMER" ]] && cp -a -- "$TIMER" "$backup/timer" || : > "$backup/timer.absent"
  systemctl is-enabled --quiet vps-guard-watch.timer 2>/dev/null && was_enabled=1
  systemctl is-active --quiet vps-guard-watch.timer 2>/dev/null && was_active=1

  _restore_watch_units() {
    if [[ -f "$backup/service" ]]; then atomic_copy_file "$backup/service" "$SERVICE" "$(stat -c '%a' "$backup/service" 2>/dev/null || echo 644)" || true; else rm -f -- "$SERVICE"; fi
    if [[ -f "$backup/timer" ]]; then atomic_copy_file "$backup/timer" "$TIMER" "$(stat -c '%a' "$backup/timer" 2>/dev/null || echo 644)" || true; else rm -f -- "$TIMER"; fi
    systemctl daemon-reload >/dev/null 2>&1 || true
    if ((was_enabled)); then systemctl enable vps-guard-watch.timer >/dev/null 2>&1 || true; else systemctl disable vps-guard-watch.timer >/dev/null 2>&1 || true; fi
    if ((was_active)); then systemctl start vps-guard-watch.timer >/dev/null 2>&1 || true; else systemctl stop vps-guard-watch.timer >/dev/null 2>&1 || true; fi
  }

  cat <<EOF_SERVICE | atomic_write_file "$SERVICE" 644 || { _restore_watch_units; return 40; }
# Managed by VPS Guard
[Unit]
Description=VPS Guard daily security watch
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash $exec_arg watch run
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=$state_arg $log_arg
UMask=0077
EOF_SERVICE
  cat <<'EOF_TIMER' | atomic_write_file "$TIMER" 644 || { _restore_watch_units; return 40; }
# Managed by VPS Guard
[Unit]
Description=Run VPS Guard security watch daily

[Timer]
OnCalendar=daily
RandomizedDelaySec=20m
Persistent=true

[Install]
WantedBy=timers.target
EOF_TIMER
  if ! systemctl daemon-reload; then _restore_watch_units; return 40; fi
  systemctl enable --now vps-guard-watch.timer >/dev/null || {
    rc=$?; _restore_watch_units; error "Watch 启用失败，已恢复修改前的 systemd unit/生命周期"; return "$rc"
  }
  ok "Watch 已启用：每天自动检查 Exposure + Drift；报告只保存在本机。"
)

disable_watch() {
  require_root || return 1; have systemctl || return 20
  _watch_units_safe_to_manage || return $?
  local service_state timer_state managed=0
  service_state="$(_watch_unit_state "$SERVICE")"; timer_state="$(_watch_unit_state "$TIMER")"
  [[ "$service_state" == managed ]] && managed=1
  [[ "$timer_state" == managed ]] && managed=1
  if ((managed==0)); then info "未发现 VPS Guard 管理的 Watch unit。"; return 0; fi
  if [[ "$timer_state" == managed ]]; then systemctl disable --now vps-guard-watch.timer >/dev/null 2>&1 || true; fi
  if [[ "$service_state" == managed ]]; then systemctl stop vps-guard-watch.service >/dev/null 2>&1 || true; fi
  [[ "$service_state" != managed ]] || rm -f -- "$SERVICE"
  [[ "$timer_state" != managed ]] || rm -f -- "$TIMER"
  systemctl daemon-reload >/dev/null 2>&1 || true
  ok "Watch 已停用；历史报告未删除。"
}

latest() {
  local f=""
  [[ -r "$WATCH_DIR/latest.state" ]] && f="$(awk -F= '$1=="report" {print substr($0,index($0,"=")+1)}' "$WATCH_DIR/latest.state")"
  [[ -n "$f" && -r "$f" ]] && cat "$f" || echo "暂无 Watch 报告"
}

set_threshold() {
  require_root || return 1; local t="${1^^}"; case "$t" in CRITICAL|HIGH|MEDIUM) ;; *) error "阈值支持: MEDIUM|HIGH|CRITICAL"; return 64;; esac
  ensure_runtime_dirs || return 40; printf 'threshold=%s\n' "$t" | atomic_write_file "$CONF" 644 || return 40; ok "Watch 通知阈值: $t"
}

menu() { status; echo; echo "1) 立即运行 2) 启用每天检查 3) 停用 4) 最新报告 5) 通知阈值 0) 返回"; read -r -p '请选择: ' c; case "$c" in 1) run_watch;; 2) enable_watch;; 3) disable_watch;; 4) latest;; 5) read -r -p 'MEDIUM/HIGH/CRITICAL: ' t; set_threshold "$t";; esac; }

action="${1:-status}"; shift || true
case "$action" in status|check) status;; run) run_watch;; enable|apply) enable_watch;; disable) disable_watch;; latest|report) latest;; threshold) set_threshold "$@";; menu) menu;; *) error "watch 支持: status|run|enable|disable|latest|threshold|menu"; exit 64;; esac
