#!/usr/bin/env bash
set -uo pipefail
VPSG_ROOT="${VPSG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
. "$VPSG_ROOT/core/common.sh"
. "$VPSG_ROOT/core/inspect.sh"
BASE_DIR="$VPSG_STATE_DIR/baselines"

_valid_name() { [[ "$1" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; }

create() {
  require_root || return 1
  local name="default" force=0
  while (($#)); do
    case "$1" in
      --force) force=1; shift ;;
      --name) name="${2:-}"; shift 2 ;;
      *) name="$1"; shift ;;
    esac
  done
  _valid_name "$name" || { error "基线名称仅允许字母、数字、点、下划线和短横线"; return 64; }
  ensure_runtime_dirs; mkdir -p "$BASE_DIR"; chmod 700 "$BASE_DIR" 2>/dev/null || true
  local dest="$BASE_DIR/$name"
  if [[ -d "$dest" && "$force" != 1 ]]; then
    error "基线已存在: $name。确认新状态可信后可使用 --force 覆盖。"
    return 30
  fi
  local tmp; tmp="$(mktemp -d "$BASE_DIR/.${name}.new.XXXXXX")"
  if ! snapshot_capture "$tmp"; then rm -rf "$tmp"; return 40; fi
  printf 'name=%s\n' "$name" >> "$tmp/manifest"
  rm -rf "$dest.old"
  [[ ! -d "$dest" ]] || mv "$dest" "$dest.old"
  mv "$tmp" "$dest"
  rm -rf "$dest.old"
  log_event INFO "baseline created name=$name"
  ok "安全基线已创建: $name"
  echo "位置: $dest"
  echo "后续检查: sudo vpsg drift scan $name"
}

list_baselines() {
  [[ -d "$BASE_DIR" ]] || { echo "暂无安全基线。"; return 0; }
  local d created host
  printf '%-24s %-28s %s\n' "NAME" "CREATED" "HOST"
  for d in "$BASE_DIR"/*; do
    [[ -d "$d" ]] || continue
    created="$(awk -F= '$1=="created" {print substr($0,index($0,"=")+1)}' "$d/manifest" 2>/dev/null)"
    host="$(awk -F= '$1=="hostname" {print $2}' "$d/manifest" 2>/dev/null)"
    printf '%-24s %-28s %s\n' "$(basename "$d")" "${created:-unknown}" "${host:-unknown}"
  done
}

show() {
  local name="${1:-default}" dir="$BASE_DIR/${1:-default}"
  _valid_name "$name" || return 64
  [[ -r "$dir/manifest" ]] || { error "基线不存在: $name"; return 20; }
  cat "$dir/manifest"
  printf 'sections='
  find "$dir" -maxdepth 1 -type f ! -name manifest -printf '%f\n' 2>/dev/null | sort | paste -sd, -
}

delete_baseline() {
  require_root || return 1
  local name="${1:-}"; _valid_name "$name" || { error "用法: sudo vpsg baseline delete <name>"; return 64; }
  [[ -d "$BASE_DIR/$name" ]] || { error "基线不存在: $name"; return 20; }
  confirm "删除基线 $name？" || return 10
  rm -rf "$BASE_DIR/$name"
  log_event INFO "baseline deleted name=$name"
  ok "基线已删除: $name"
}

action="${1:-list}"; shift || true
parse_yes_flag "$@"
case "$action" in
  create) create "$@" ;;
  list|status) list_baselines ;;
  show) show "$@" ;;
  delete) delete_baseline "$@" ;;
  *) error "baseline 支持: create [name] [--force]|list|show [name]|delete <name>"; exit 64 ;;
esac
