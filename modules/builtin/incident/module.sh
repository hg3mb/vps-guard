#!/usr/bin/env bash
set -uo pipefail
VPSG_ROOT="${VPSG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
. "$VPSG_ROOT/core/common.sh"
OUT_DIR="$VPSG_STATE_DIR/incidents"
collect() {
  require_root || return 1; ensure_runtime_dirs; mkdir -p "$OUT_DIR"; chmod 700 "$OUT_DIR"
  local stamp work archive; stamp="$(date +%Y%m%d-%H%M%S)"; work="$(mktemp -d)"; trap 'rm -rf "$work"' RETURN; archive="$OUT_DIR/incident-$stamp.tar.gz"
  { echo "collected=$(date -Is)"; echo "hostname=$(hostname)"; echo "kernel=$(uname -a)"; } > "$work/system.txt"
  { getent passwd; echo; echo '=== groups ==='; getent group; } > "$work/accounts.txt" 2>/dev/null || true
  { ps auxww; } > "$work/processes.txt" 2>/dev/null || true
  { ss -lntup; echo; ss -antup; } > "$work/sockets.txt" 2>/dev/null || true
  { ip addr; echo; ip route; echo; ip -6 route; } > "$work/network.txt" 2>/dev/null || true
  { last -n 100; echo; lastb -n 100 2>/dev/null || true; } > "$work/logins.txt" 2>/dev/null || true
  { journalctl -u ssh -u sshd --since '24 hours ago' --no-pager 2>/dev/null || true; } > "$work/ssh-journal.txt"
  { journalctl -u fail2ban --since '24 hours ago' --no-pager 2>/dev/null || true; } > "$work/fail2ban-journal.txt"
  { /bin/bash "$VPSG_ROOT/modules/builtin/firewall/module.sh" status 2>/dev/null || true; } > "$work/firewall.txt"
  { systemctl --failed --no-pager 2>/dev/null || true; echo; systemctl list-unit-files --state=enabled --no-pager 2>/dev/null || true; } > "$work/systemd.txt"
  { crontab -l 2>/dev/null || true; echo; find /etc/cron.d -maxdepth 1 -type f -printf '%p\n' 2>/dev/null || true; } > "$work/cron-index.txt"
  { if command -v docker >/dev/null 2>&1; then docker ps -a; echo; docker images; echo; docker network ls; fi; } > "$work/docker.txt" 2>/dev/null || true
  # Intentionally do not copy private keys, authorized_keys contents, environment files or application data.
  (cd "$work" && sha256sum ./* > SHA256SUMS)
  tar -C "$work" -czf "$archive" .; chmod 600 "$archive"; log_event INFO "incident bundle created archive=$archive"
  ok "只读现场包已生成: $archive"; echo "注意：报告仍可能包含用户名、IP、进程和容器名称，分享前请人工检查。"
}
list_reports() { [[ -d "$OUT_DIR" ]] || { echo "暂无现场包。"; return 0; }; ls -lh "$OUT_DIR"/incident-*.tar.gz 2>/dev/null || echo "暂无现场包。"; }
action="${1:-list}"; shift || true
case "$action" in collect|apply) collect;; list|status) list_reports;; *) error "incident 支持: collect|list"; exit 64;; esac
