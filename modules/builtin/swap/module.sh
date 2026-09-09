#!/usr/bin/env bash
set -uo pipefail
VPSG_ROOT="${VPSG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
. "$VPSG_ROOT/core/common.sh"
. "$VPSG_ROOT/core/platform.sh"
SWAPFILE="${VPSG_SWAPFILE:-/swapfile.vps-guard}"
STATE="$VPSG_STATE_DIR/swap-last.state"

current_swap_mb() { awk 'NR>1 {sum += $3} END {printf "%d\n", sum/1024}' /proc/swaps; }
recommend_mb() { local m; m="$(memory_mb)"; if ((m<=1024)); then echo 1024; elif ((m<=4096)); then echo 2048; else echo 2048; fi; }
unit_name_for() { systemd-escape --path --suffix=swap "$1"; }
unit_file_for() { printf '%s/%s\n' "$VPSG_SYSTEMD_DIR" "$(unit_name_for "$1")"; }
unit_name() { unit_name_for "$SWAPFILE"; }
unit_file() { unit_file_for "$SWAPFILE"; }
_swap_state_get() { awk -F= -v k="$1" '$1==k {print substr($0,index($0,"=")+1)}' "$STATE" 2>/dev/null | tail -1; }
_swap_identity() { stat -Lc '%d:%i:%s:%y:%z' "$1" 2>/dev/null; }
_swap_path_valid() {
  local p="${1:-}" n
  [[ "$p" == /* ]] || return 1
  n="$(path_normalize_lexical "$p")" || return 1
  [[ "$n" == "$p" && "$p" != / ]] || return 1
}
_swap_unit_owned() {
  local file="$1" expected="$2"
  vpsg_file_is_managed "$file" || return 1
  grep -Fqx "What=$expected" "$file" 2>/dev/null
}
_swap_legacy_unit_owned() {
  local file="$1" expected="$2"
  [[ "$expected" == /swapfile.vps-guard && -f "$file" && ! -L "$file" ]] || return 1
  grep -Fqx 'Description=VPS Guard swap file' "$file" 2>/dev/null && grep -Fqx "What=$expected" "$file" 2>/dev/null
}
status() { local s; s="$(current_swap_mb)"; [[ "${1:-}" == --brief ]] && echo "${s}MB" || { echo "已启用 Swap: ${s} MB"; [[ -e "$SWAPFILE" ]] && echo "VPS Guard swapfile: $SWAPFILE"; }; }
plan() { local existing rec free; existing="$(current_swap_mb)"; rec="$(recommend_mb)"; free="$(root_free_mb)"; if ((existing>0)); then echo "系统已有 ${existing} MB Swap；默认保持现状。"; return 10; fi; echo "建议创建 ${rec} MB Swap；根分区可用 ${free} MB。"; echo "使用独立 swapfile + systemd swap unit，不修改 /etc/fstab。"; }
_cleanup_failed_create() {
  local unit file
  unit="$(unit_name 2>/dev/null || true)"; file="$(unit_file 2>/dev/null || true)"
  [[ -n "$unit" ]] && systemctl disable --now "$unit" >/dev/null 2>&1 || true
  swapoff "$SWAPFILE" >/dev/null 2>&1 || true
  [[ -n "$file" ]] && _swap_unit_owned "$file" "$SWAPFILE" && rm -f -- "$file"
  [[ -L "$SWAPFILE" ]] || [[ ! -e "$SWAPFILE" ]] || rm -f -- "$SWAPFILE"
  systemctl daemon-reload >/dev/null 2>&1 || true
}
apply() {
  require_root || return 1; have systemctl && have systemd-escape || { error "Swap 管理需要 systemd"; return 20; }
  local size; size="$(recommend_mb)"
  while (($#)); do case "$1" in --size-mb) [[ $# -ge 2 ]] || return 64; size="$2"; shift 2;; --yes|-y) VPSG_ASSUME_YES=1; shift;; *) error "未知参数: $1"; return 64;; esac; done
  [[ "$size" =~ ^[0-9]+$ ]] && ((size>=256 && size<=16384)) || { error "Swap 大小必须为 256-16384 MB"; return 64; }
  _swap_path_valid "$SWAPFILE" || { error "Swapfile 路径必须是规范化绝对路径: $SWAPFILE"; return 64; }
  local existing free unit file identity; existing="$(current_swap_mb)"; ((existing==0)) || { warn "已有 Swap，跳过创建"; return 10; }; free="$(root_free_mb)"; ((free>=size+1024)) || { error "磁盘空间不足；创建后至少保留 1GB"; return 30; }
  [[ ! -e "$SWAPFILE" && ! -L "$SWAPFILE" ]] || { error "$SWAPFILE 已存在，拒绝覆盖"; return 30; }
  unit="$(unit_name)" || return 20; file="$(unit_file)" || return 20
  [[ ! -e "$file" && ! -L "$file" ]] || { error "systemd unit 已存在，拒绝覆盖: $file"; return 30; }
  echo "计划创建 ${size} MB Swap: $SWAPFILE"; confirm "继续？" || return 10
  ensure_runtime_dirs || return 40
  if have fallocate; then fallocate -l "${size}M" "$SWAPFILE" || { _cleanup_failed_create; return 40; }; else dd if=/dev/zero of="$SWAPFILE" bs=1M count="$size" status=none || { _cleanup_failed_create; return 40; }; fi
  chmod 600 "$SWAPFILE" || { _cleanup_failed_create; return 40; }
  [[ -f "$SWAPFILE" && ! -L "$SWAPFILE" ]] || { _cleanup_failed_create; return 40; }
  mkswap "$SWAPFILE" >/dev/null || { _cleanup_failed_create; return 40; }
  identity="$(_swap_identity "$SWAPFILE")"; [[ -n "$identity" ]] || { _cleanup_failed_create; return 40; }
  cat <<EOF_UNIT | atomic_write_file "$file" 644 || { _cleanup_failed_create; return 40; }
# Managed by VPS Guard
[Unit]
Description=VPS Guard swap file

[Swap]
What=$SWAPFILE

[Install]
WantedBy=swap.target
EOF_UNIT
  systemctl daemon-reload || { _cleanup_failed_create; return 40; }
  systemctl enable --now "$unit" >/dev/null || { _cleanup_failed_create; return 40; }
  verify || { _cleanup_failed_create; return 50; }
  cat <<EOF_STATE | atomic_write_file "$STATE" 600 || { _cleanup_failed_create; return 40; }
schema=2
swapfile=$SWAPFILE
file_identity=$identity
size_mb=$size
created_epoch=$(date +%s)
EOF_STATE
  log_event INFO "swap created path=$SWAPFILE size_mb=$size"; ok "Swap 已创建: $SWAPFILE"
}
verify() { awk -v f="$SWAPFILE" 'NR>1 && $1==f {found=1} END {exit !found}' /proc/swaps || return 1; ok "Swap 已启用: $SWAPFILE"; }
rollback() {
  require_root || return 1; [[ -r "$STATE" && ! -L "$STATE" ]] || { error "没有可信的 VPS Guard Swap 回滚状态"; return 20; }
  local target identity actual unit file schema
  schema="$(_swap_state_get schema)"; target="$(_swap_state_get swapfile)"; identity="$(_swap_state_get file_identity)"
  if [[ -z "$target" ]]; then target=/swapfile.vps-guard; fi
  _swap_path_valid "$target" || { error "Swap 状态中的路径异常，拒绝删除: $target"; return 30; }
  if [[ -n "$identity" ]]; then
    [[ -f "$target" && ! -L "$target" ]] || { error "Swapfile 已不存在或类型异常，拒绝继续: $target"; return 30; }
    actual="$(_swap_identity "$target")"; [[ "$actual" == "$identity" ]] || { error "Swapfile 身份已变化，拒绝删除: $target"; return 30; }
  else
    # v0.3 legacy state did not bind resource identity. Fail closed for custom paths;
    # only the historical default filename is eligible for legacy rollback.
    [[ "$target" == /swapfile.vps-guard && -f "$target" && ! -L "$target" ]] || { error "旧版 Swap 状态缺少文件身份信息，拒绝非默认路径回滚"; return 30; }
  fi
  unit="$(unit_name_for "$target")" || return 20; file="$(unit_file_for "$target")" || return 20
  if [[ -e "$file" || -L "$file" ]]; then
    if ! _swap_unit_owned "$file" "$target" && ! { [[ -z "$schema" ]] && _swap_legacy_unit_owned "$file" "$target"; }; then
      error "同名 systemd swap unit 不再属于 VPS Guard，拒绝删除: $file"; return 30
    fi
    systemctl disable --now "$unit" >/dev/null 2>&1 || swapoff "$target" >/dev/null 2>&1 || true
  else
    swapoff "$target" >/dev/null 2>&1 || true
  fi
  if [[ -n "$identity" ]]; then [[ "$(_swap_identity "$target")" == "$identity" ]] || { error "Swapfile 在回滚过程中发生变化，拒绝删除"; return 30; }; fi
  rm -f -- "$file" "$target" || return 40
  rm -f -- "$STATE" || return 40
  systemctl daemon-reload >/dev/null 2>&1 || true
  [[ ! -e "$target" && ! -L "$target" ]] || { error "Swapfile 删除失败"; return 50; }; ok "VPS Guard 创建的 Swap 已移除: $target"
}
action="${1:-status}"; shift || true; parse_yes_flag "$@"
case "$action" in status|check) status "$@";; plan) plan;; apply) apply "$@";; verify) verify;; rollback) rollback;; *) error "swap 支持: status|plan|apply|verify|rollback"; exit 64;; esac
