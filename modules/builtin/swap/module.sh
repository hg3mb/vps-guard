#!/usr/bin/env bash
set -uo pipefail
VPSG_ROOT="${VPSG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
. "$VPSG_ROOT/core/common.sh"
. "$VPSG_ROOT/core/platform.sh"
SWAPFILE="/swapfile.vps-guard"
STATE="$VPSG_STATE_DIR/swap-last.state"

current_swap_mb() { awk 'NR>1 {sum += $3} END {printf "%d\n", sum/1024}' /proc/swaps; }
recommend_mb() {
  local m; m="$(memory_mb)"
  if (( m <= 1024 )); then echo 1024; elif (( m <= 2048 )); then echo 2048; elif (( m <= 4096 )); then echo 2048; else echo 2048; fi
}
unit_name() { systemd-escape --path --suffix=swap "$SWAPFILE"; }

status() {
  local s; s="$(current_swap_mb)"
  [[ "${1:-}" == "--brief" ]] && echo "${s}MB" || echo "已启用 Swap: ${s} MB"
}

plan() {
  local existing rec free
  existing="$(current_swap_mb)"; rec="$(recommend_mb)"; free="$(root_free_mb)"
  if (( existing > 0 )); then echo "系统已有 ${existing} MB Swap；默认保持现状。"; return 10; fi
  echo "建议创建 ${rec} MB Swap；根分区当前可用 ${free} MB。"
  echo "使用独立 swapfile 和 systemd swap unit，不修改 /etc/fstab。"
}

apply() {
  require_root || return 1
  local size="$(recommend_mb)"
  while (($#)); do case "$1" in --size-mb) size="${2:-}"; shift 2;; --yes|-y) VPSG_ASSUME_YES=1; shift;; *) shift;; esac; done
  [[ "$size" =~ ^[0-9]+$ ]] && (( size >= 256 && size <= 16384 )) || { error "Swap 大小必须为 256-16384 MB"; return 64; }
  local existing free; existing="$(current_swap_mb)"
  (( existing == 0 )) || { warn "已有 Swap，跳过创建"; return 10; }
  free="$(root_free_mb)"; (( free >= size + 1024 )) || { error "磁盘空间不足；需至少保留 1GB 安全余量"; return 30; }
  echo "计划创建 ${size} MB Swap: $SWAPFILE"
  confirm "继续？" || return 10
  ensure_runtime_dirs
  local unit; unit="$(unit_name)" || return 20
  [[ ! -e "$SWAPFILE" ]] || { error "$SWAPFILE 已存在，拒绝覆盖"; return 30; }
  if have fallocate; then fallocate -l "${size}M" "$SWAPFILE"; else dd if=/dev/zero of="$SWAPFILE" bs=1M count="$size" status=progress; fi
  chmod 600 "$SWAPFILE"
  mkswap "$SWAPFILE" >/dev/null || { rm -f "$SWAPFILE"; return 40; }
  cat > "/etc/systemd/system/$unit" <<UNIT
[Unit]
Description=VPS Guard swap file

[Swap]
What=$SWAPFILE

[Install]
WantedBy=swap.target
UNIT
  systemctl daemon-reload
  systemctl enable --now "$unit" >/dev/null || return 40
  printf 'unit=%s\nsize_mb=%s\n' "$unit" "$size" > "$STATE"
  verify || return 50
  log_event INFO "swap created size_mb=$size"
}

verify() {
  awk -v f="$SWAPFILE" 'NR>1 && $1==f {found=1} END {exit !found}' /proc/swaps || return 1
  ok "Swap 已启用: $SWAPFILE"
}

rollback() {
  require_root || return 1
  [[ -r "$STATE" ]] || { error "没有 Swap 回滚状态"; return 20; }
  local unit; unit="$(awk -F= '$1=="unit" {print $2}' "$STATE")"
  systemctl disable --now "$unit" >/dev/null 2>&1 || swapoff "$SWAPFILE" 2>/dev/null || true
  rm -f "/etc/systemd/system/$unit" "$SWAPFILE"
  systemctl daemon-reload
  ok "VPS Guard 创建的 Swap 已移除"
}

action="${1:-status}"; shift || true
parse_yes_flag "$@"
case "$action" in
  status|check) status "$@" ;;
  plan) plan ;;
  apply) apply "$@" ;;
  verify) verify ;;
  rollback) rollback ;;
  *) error "swap 支持: status|plan|apply|verify|rollback"; exit 64 ;;
esac
