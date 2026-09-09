#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$ROOT/core/common.sh"
DEST="${VPSG_INSTALL_DEST:-/usr/lib/vps-guard}"; LINK="${VPSG_INSTALL_LINK:-/usr/local/bin/vpsg}"; STATE_DIR="${VPSG_INSTALL_STATE_DIR:-/var/lib/vps-guard}"; ETC_DIR="${VPSG_INSTALL_ETC_DIR:-/etc/vps-guard}"; LOG_DIR="${VPSG_INSTALL_LOG_DIR:-/var/log/vps-guard}"; ALLOW_NONROOT="${VPSG_INSTALL_ALLOW_NONROOT:-0}"
[[ "$ALLOW_NONROOT" == 1 || ${EUID:-$(id -u)} -eq 0 ]] || { echo "请使用 sudo ./uninstall.sh" >&2; exit 1; }
purge=0; yes=0
while (($#)); do case "$1" in --purge-data) purge=1;; --yes|-y) yes=1;; *) echo "未知参数: $1" >&2; exit 64;; esac; shift; done

for p in "$DEST" "$STATE_DIR" "$ETC_DIR" "$LOG_DIR"; do n="$(path_normalize_lexical "$p")"; [[ "$n" == "$p" ]] || { echo "拒绝非规范化路径: $p" >&2; exit 70; }; _path_is_dangerous_root "$n" && { echo "拒绝危险路径: $n" >&2; exit 70; }; done

# Never remove the program while a rollback safety net may still be needed.
# Transaction state records are the source of truth; `current` is only a cache.
# Inspect every record and fail closed on malformed/unknown state so a missing
# pointer, symlinked state file, or half-written record cannot bypass protection.
_tx_uninstall_status_kind() {
  case "${1:-}" in
    preparing|applying|pending|commit_pending|apply_failed|rolling_back|rollback_failed) echo active ;;
    committed|rolled_back|prepare_failed|schedule_failed) echo terminal ;;
    *) echo unknown ;;
  esac
}
_tx_uninstall_check_record() {
  local dir="$1" id state status kind
  id="$(basename "$dir")"
  [[ "$id" =~ ^[0-9]{8}-[0-9]{6}-[0-9]{1,10}-[0-9a-f]{4}$ && -d "$dir" && ! -L "$dir" ]] || {
    echo "拒绝卸载：发现格式异常/不可信的 Safe Change 事务记录: $dir" >&2; return 30;
  }
  state="$dir/state"
  [[ -f "$state" && ! -L "$state" && -r "$state" ]] || {
    echo "拒绝卸载：Safe Change 事务缺少可信 state 文件: $id" >&2; return 30;
  }
  status="$(awk -F= '$1=="status" {print $2}' "$state" 2>/dev/null | tail -1)"
  kind="$(_tx_uninstall_status_kind "$status")"
  case "$kind" in
    active)
      echo "拒绝卸载：存在未完成 Safe Change ($id, $status)。请先 commit/rollback 并确认恢复成功。" >&2
      return 30;;
    terminal) return 0;;
    *)
      echo "拒绝卸载：Safe Change 事务状态未知 ($id, ${status:-missing})。请先人工检查。" >&2
      return 30;;
  esac
}

txroot="$STATE_DIR/transactions"
if [[ -e "$txroot" || -L "$txroot" ]]; then
  [[ -d "$txroot" && ! -L "$txroot" ]] || { echo "拒绝卸载：Safe Change 事务目录不可信: $txroot" >&2; exit 30; }
  for entry in "$txroot"/*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    [[ "$entry" == "$txroot/current" ]] && continue
    # Lock/cache files may coexist with transaction directories. Anything that
    # looks like a transaction directory must be structurally valid.
    [[ -d "$entry" || -L "$entry" ]] || continue
    _tx_uninstall_check_record "$entry" || exit 30
  done
fi

current="$STATE_DIR/transactions/current"
if [[ -e "$current" || -L "$current" ]]; then
  [[ -f "$current" && ! -L "$current" && -r "$current" ]] || {
    echo "拒绝卸载：Safe Change current 指针不可信。请先检查 $current" >&2; exit 30;
  }
  id="$(cat "$current" 2>/dev/null || true)"
  [[ "$id" =~ ^[0-9]{8}-[0-9]{6}-[0-9]{1,10}-[0-9a-f]{4}$ ]] || {
    echo "拒绝卸载：Safe Change current 指针格式异常。请先检查 $current" >&2; exit 30;
  }
  _tx_uninstall_check_record "$STATE_DIR/transactions/$id" || exit 30
fi

if command -v systemctl >/dev/null 2>&1; then
  watch_service="$VPSG_SYSTEMD_DIR/vps-guard-watch.service"; watch_timer="$VPSG_SYSTEMD_DIR/vps-guard-watch.timer"
  service_owned=0; timer_owned=0; foreign=0
  if [[ -e "$watch_service" || -L "$watch_service" ]]; then vpsg_file_is_managed "$watch_service" && service_owned=1 || foreign=1; fi
  if [[ -e "$watch_timer" || -L "$watch_timer" ]]; then vpsg_file_is_managed "$watch_timer" && timer_owned=1 || foreign=1; fi
  if ((foreign)); then
    echo "保留同名但非 VPS Guard 管理的 Watch systemd unit；请人工检查。" >&2
  else
    ((timer_owned==0)) || systemctl disable --now vps-guard-watch.timer >/dev/null 2>&1 || true
    ((service_owned==0)) || systemctl stop vps-guard-watch.service >/dev/null 2>&1 || true
    ((timer_owned==0)) || rm -f -- "$watch_timer"
    ((service_owned==0)) || rm -f -- "$watch_service"
    ((timer_owned==0 && service_owned==0)) || systemctl daemon-reload >/dev/null 2>&1 || true
  fi
fi
if [[ -L "$LINK" && "$(readlink "$LINK" 2>/dev/null || true)" == "$DEST/bin/vpsg" ]]; then rm -f -- "$LINK"; fi
[[ ! -e "$DEST" ]] || safe_rm_rf_within "$DEST" "$(dirname "$DEST")"
echo "VPS Guard 程序已卸载。SSH/UFW/Fail2Ban 等系统安全配置不会被自动撤销。"
if ((purge)); then
  echo "还将永久删除 VPS Guard 私有数据："; printf '  %s\n' "$STATE_DIR" "$ETC_DIR" "$LOG_DIR"
  if ((!yes)); then read -r -p '确认永久删除这些数据？输入 DELETE: ' ans; [[ "$ans" == DELETE ]] || { echo "已保留数据。"; exit 0; }; fi
  [[ ! -e "$ETC_DIR" ]] || safe_rm_rf_within "$ETC_DIR" "$(dirname "$ETC_DIR")"
  [[ ! -e "$LOG_DIR" ]] || safe_rm_rf_within "$LOG_DIR" "$(dirname "$LOG_DIR")"
  [[ ! -e "$STATE_DIR" ]] || safe_rm_rf_within "$STATE_DIR" "$(dirname "$STATE_DIR")"
  echo "VPS Guard 私有数据已删除。"
else echo "已保留: $STATE_DIR, $ETC_DIR, $LOG_DIR"; fi
