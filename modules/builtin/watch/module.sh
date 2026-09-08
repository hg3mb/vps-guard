#!/usr/bin/env bash
set -uo pipefail
VPSG_ROOT="${VPSG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
. "$VPSG_ROOT/core/common.sh"
REPORT_DIR="$VPSG_STATE_DIR/watch/reports"; SERVICE=/etc/systemd/system/vps-guard-watch.service; TIMER=/etc/systemd/system/vps-guard-watch.timer
run_watch() {
  require_root || return 1; ensure_runtime_dirs; mkdir -p "$REPORT_DIR"; local out="$REPORT_DIR/$(date +%Y%m%d-%H%M%S).log" rc=0
  { echo "VPS Guard Watch — $(date -Is)"; echo; echo "=== Exposure ==="; /bin/bash "$VPSG_ROOT/modules/builtin/exposure/module.sh" scan; echo; echo "=== Drift ==="; if [[ -d "$VPSG_STATE_DIR/baselines/default" ]]; then /bin/bash "$VPSG_ROOT/modules/builtin/drift/module.sh" scan default --strict || rc=$?; else echo "尚未创建 default 基线。运行 sudo vpsg baseline create"; fi; } > "$out" 2>&1
  log_event INFO "watch run report=$out drift_rc=$rc"; echo "报告: $out"; return 0
}
status() { if have systemctl && systemctl is-enabled --quiet vps-guard-watch.timer 2>/dev/null; then echo "VPS Guard Watch: 已启用"; systemctl list-timers vps-guard-watch.timer --no-pager 2>/dev/null || true; else echo "VPS Guard Watch: 未启用"; fi; }
enable_watch() { require_root || return 1; have systemctl || return 20; cat > "$SERVICE" <<EOF
[Unit]
Description=VPS Guard daily security watch
[Service]
Type=oneshot
ExecStart=/usr/local/bin/vpsg watch run
EOF
  cat > "$TIMER" <<EOF
[Unit]
Description=Run VPS Guard security watch daily
[Timer]
OnCalendar=daily
RandomizedDelaySec=20m
Persistent=true
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload; systemctl enable --now vps-guard-watch.timer >/dev/null; ok "Watch 已启用，每天运行一次；异常记录在本机，不会自动上传数据。"; }
disable_watch() { require_root || return 1; systemctl disable --now vps-guard-watch.timer >/dev/null 2>&1 || true; rm -f "$SERVICE" "$TIMER"; systemctl daemon-reload; ok "Watch 已停用"; }
latest() { [[ -d "$REPORT_DIR" ]] || { echo "暂无 Watch 报告"; return 0; }; local f; f="$(find "$REPORT_DIR" -maxdepth 1 -type f | sort -r | head -1)"; [[ -n "$f" ]] && cat "$f" || echo "暂无 Watch 报告"; }
menu() { status; echo "1) 立即运行 2) 启用每天检查 3) 停用 4) 看最新报告 0) 返回"; read -r -p '请选择: ' c; case "$c" in 1) run_watch;; 2) enable_watch;; 3) disable_watch;; 4) latest;; esac; }
action="${1:-status}"; shift || true
case "$action" in status|check) status;; run) run_watch;; enable|apply) enable_watch;; disable) disable_watch;; latest|report) latest;; menu) menu;; *) error "watch 支持: status|run|enable|disable|latest|menu"; exit 64;; esac
