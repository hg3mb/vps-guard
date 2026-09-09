#!/usr/bin/env bash
set -uo pipefail
VPSG_ROOT="${VPSG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
. "$VPSG_ROOT/core/common.sh"
OUT_DIR="$VPSG_STATE_DIR/incidents"

_collect_cmd() { local out="$1"; shift; "$@" > "$out" 2>&1 || true; chmod 600 "$out" 2>/dev/null || true; }

collect() (
  require_root || return 1
  local include_cmd=0 a
  while (($#)); do a="$1"; shift; case "$a" in --include-command-lines) include_cmd=1;; --yes|-y) VPSG_ASSUME_YES=1;; *) error "未知参数: $a"; return 64;; esac; done
  ensure_runtime_dirs || return 40; mkdir -p "$OUT_DIR" || return 40; chmod 700 "$OUT_DIR"
  local stamp work archive
  stamp="$(date +%Y%m%d-%H%M%S)-$$"; work="$(mktemp -d "$VPSG_STATE_DIR/.incident.XXXXXX")" || return 40
  trap 'rm -rf -- "$work"' EXIT
  archive="$OUT_DIR/incident-$stamp.tar.gz"
  umask 077
  {
    echo "collected=$(date -Is)"; echo "hostname=$(hostname)"; echo "kernel=$(uname -a)"; [[ -r /etc/os-release ]] && cat /etc/os-release
    echo "privacy=command_lines_$([[ $include_cmd -eq 1 ]] && echo included || echo omitted)"
  } > "$work/system.txt"
  { getent passwd; echo; echo '=== groups ==='; getent group; } > "$work/accounts.txt" 2>/dev/null || true
  if ((include_cmd)); then ps -eo user,pid,ppid,stat,lstart,args --sort=pid > "$work/processes.txt" 2>&1 || true
  else ps -eo user,pid,ppid,stat,lstart,comm --sort=pid > "$work/processes.txt" 2>&1 || true; fi
  { ss -lntup 2>/dev/null || true; echo; ss -antup 2>/dev/null || true; } > "$work/sockets.txt"
  { ip addr 2>/dev/null || true; echo; ip route 2>/dev/null || true; echo; ip -6 route 2>/dev/null || true; } > "$work/network.txt"
  { last -n 100 2>/dev/null || true; echo; lastb -n 100 2>/dev/null || true; } > "$work/logins.txt"
  journalctl -u ssh -u sshd --since '24 hours ago' --no-pager > "$work/ssh-journal.txt" 2>&1 || true
  journalctl -u fail2ban --since '24 hours ago' --no-pager > "$work/fail2ban-journal.txt" 2>&1 || true
  /bin/bash "$VPSG_ROOT/modules/builtin/firewall/module.sh" status > "$work/firewall.txt" 2>&1 || true
  { systemctl --failed --no-pager 2>/dev/null || true; echo; systemctl list-unit-files --state=enabled --no-pager 2>/dev/null || true; } > "$work/systemd.txt"
  {
    echo '=== system cron locations (metadata only) ==='
    find /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly -maxdepth 1 -type f -printf '%M %u:%g %s %TY-%Tm-%Td %TH:%TM %p\n' 2>/dev/null | LC_ALL=C sort
    echo; echo '=== user crontab owners ==='; ls -ln /var/spool/cron/crontabs /var/spool/cron 2>/dev/null || true
  } > "$work/cron-index.txt"
  if have docker; then
    { docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || true; echo; docker network ls 2>/dev/null || true; } > "$work/docker.txt"
  else echo 'Docker not installed' > "$work/docker.txt"; fi
  { df -hT; echo; free -m; echo; uptime; } > "$work/resources.txt" 2>&1 || true
  chmod 600 "$work"/* 2>/dev/null || true
  (cd "$work" && find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%P\n' | LC_ALL=C sort | xargs -r sha256sum > SHA256SUMS) || return 40
  (cd "$work" && sha256sum -c SHA256SUMS >/dev/null) || { error "现场包内部 SHA256 校验失败"; return 50; }
  tar -C "$work" -czf "$archive" . || return 40; chmod 600 "$archive" || return 40
  log_event INFO "incident collected archive=$archive command_lines=$include_cmd"
  ok "现场包已生成: $archive"
  ((include_cmd)) || echo "隐私模式：未采集完整进程命令行，避免 argv 中可能存在的 token/密码。需要时显式加 --include-command-lines。"
)

action="${1:-collect}"; shift || true
case "$action" in collect|apply) collect "$@";; status|list) [[ -d "$OUT_DIR" ]] && find "$OUT_DIR" -maxdepth 1 -type f -name 'incident-*.tar.gz' -printf '%f\n' | sort -r || echo "暂无现场包";; *) error "incident 支持: collect [--include-command-lines]|list"; exit 64;; esac
