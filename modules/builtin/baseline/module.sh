#!/usr/bin/env bash
set -uo pipefail
VPSG_ROOT="${VPSG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
. "$VPSG_ROOT/core/common.sh"
. "$VPSG_ROOT/core/inspect.sh"
BASE_DIR="$VPSG_STATE_DIR/baselines"
_valid_name() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; }

create() {
  require_root || return 1
  local name=default force=0 dest tmp old incomplete
  while (($#)); do case "$1" in --force) force=1; shift;; --name) [[ $# -ge 2 ]] || return 64; name="$2"; shift 2;; --yes|-y) VPSG_ASSUME_YES=1; shift;; *) name="$1"; shift;; esac; done
  _valid_name "$name" || { error "基线名称必须以字母/数字开头，仅允许字母、数字、点、下划线和短横线"; return 64; }
  ensure_runtime_dirs || return 40; mkdir -p "$BASE_DIR" || return 40; chmod 700 "$BASE_DIR" 2>/dev/null || true
  dest="$BASE_DIR/$name"
  if [[ -d "$dest" && "$force" != 1 ]]; then error "基线已存在: $name。确认当前状态可信后可使用 --force 覆盖。"; return 30; fi
  if [[ -d "$dest" ]]; then echo "即将用当前系统状态替换基线 '$name'。只有确认当前 VPS 可信时才应继续。"; confirm "覆盖基线？" || return 10; fi
  tmp="$(mktemp -d "$BASE_DIR/.${name}.new.XXXXXX")" || return 40
  if ! snapshot_capture "$tmp"; then safe_rm_rf_within "$tmp" "$BASE_DIR" 2>/dev/null || true; return 40; fi
  printf 'name=%s\n' "$name" >> "$tmp/manifest" || { safe_rm_rf_within "$tmp" "$BASE_DIR" 2>/dev/null || true; return 40; }
  snapshot_seal "$tmp" || { safe_rm_rf_within "$tmp" "$BASE_DIR" 2>/dev/null || true; return 40; }
  snapshot_verify "$tmp" || { safe_rm_rf_within "$tmp" "$BASE_DIR" 2>/dev/null || true; error "新基线封存自检失败"; return 50; }
  old="${dest}.old.$$"; safe_rm_rf_within "$old" "$BASE_DIR" 2>/dev/null || true
  [[ ! -d "$dest" ]] || mv -- "$dest" "$old" || { safe_rm_rf_within "$tmp" "$BASE_DIR" 2>/dev/null || true; return 40; }
  if ! mv -- "$tmp" "$dest"; then [[ ! -d "$old" ]] || mv -- "$old" "$dest" 2>/dev/null || true; return 40; fi
  safe_rm_rf_within "$old" "$BASE_DIR" 2>/dev/null || true
  incomplete="$(snapshot_incomplete_count "$dest")"
  log_event INFO "baseline created name=$name incomplete=$incomplete"
  ok "安全基线已创建并封存: $name"
  if ((incomplete>0)); then warn "该基线包含 $incomplete 个不完整采集器。'未发现变化' 不代表这些区域已被完整检查。"; awk -F'\t' '$2!="ok" {print "  - "$1": "$2}' "$dest/collection.tsv" >&2; fi
  echo "后续检查: sudo vpsg drift scan $name"
}

verify_baseline() {
  local name="${1:-default}" dir schema incomplete
  _valid_name "$name" || return 64; dir="$BASE_DIR/$name"; [[ -d "$dir" ]] || { error "基线不存在: $name"; return 20; }
  schema="$(awk -F= '$1=="schema" {print $2}' "$dir/manifest" 2>/dev/null | tail -1)"
  if [[ "$schema" != 2 || ! -r "$dir/checksums.sha256" ]]; then error "基线 '$name' 来自旧 schema，缺少 v0.4 完整性封存。确认当前 VPS 可信后重新创建。"; return 30; fi
  snapshot_verify "$dir" || { error "基线完整性验证失败：内容或文件集合已变化"; return 50; }
  incomplete="$(snapshot_incomplete_count "$dir")"; ok "Baseline integrity OK: $name"
  if ((incomplete>0)); then warn "该基线包含 $incomplete 个不完整采集器。"; awk -F'\t' '$2!="ok" {print "  - "$1": "$2}' "$dir/collection.tsv" >&2; fi
}

list_baselines() {
  [[ -d "$BASE_DIR" ]] || { echo "暂无安全基线。"; return 0; }
  local d created host incomplete
  printf '%-24s %-28s %-20s %s\n' NAME CREATED HOST INCOMPLETE
  for d in "$BASE_DIR"/*; do [[ -d "$d" ]] || continue; created="$(awk -F= '$1=="created" {print substr($0,index($0,"=")+1)}' "$d/manifest" 2>/dev/null)"; host="$(awk -F= '$1=="hostname" {print $2}' "$d/manifest" 2>/dev/null)"; incomplete="$(snapshot_incomplete_count "$d")"; printf '%-24s %-28s %-20s %s\n' "$(basename "$d")" "${created:-unknown}" "${host:-unknown}" "$incomplete"; done
}
show() { local name="${1:-default}" dir; _valid_name "$name" || return 64; dir="$BASE_DIR/$name"; [[ -r "$dir/manifest" ]] || { error "基线不存在: $name"; return 20; }; cat "$dir/manifest"; [[ ! -r "$dir/collection.tsv" ]] || { echo; echo 'collection:'; cat "$dir/collection.tsv"; }; }
delete_baseline() { require_root || return 1; local name="${1:-}"; _valid_name "$name" || { error "用法: sudo vpsg baseline delete <name>"; return 64; }; [[ -d "$BASE_DIR/$name" ]] || return 20; confirm "删除基线 $name？" || return 10; safe_rm_rf_within "$BASE_DIR/$name" "$BASE_DIR" || return 70; log_event INFO "baseline deleted name=$name"; ok "基线已删除: $name"; }

action="${1:-list}"; shift || true; parse_yes_flag "$@"
case "$action" in create) create "$@";; verify) verify_baseline "$@";; list|status) list_baselines;; show) show "$@";; delete) delete_baseline "$@";; *) error "baseline 支持: create [name] [--force]|verify [name]|list|show [name]|delete <name>"; exit 64;; esac
