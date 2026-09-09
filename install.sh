#!/usr/bin/env bash
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=core/common.sh
. "$SRC/core/common.sh"

DEST="${VPSG_INSTALL_DEST:-/usr/lib/vps-guard}"
LINK="${VPSG_INSTALL_LINK:-/usr/local/bin/vpsg}"
STATE_DIR="${VPSG_INSTALL_STATE_DIR:-/var/lib/vps-guard}"
ETC_DIR="${VPSG_INSTALL_ETC_DIR:-/etc/vps-guard}"
LOG_DIR="${VPSG_INSTALL_LOG_DIR:-/var/log/vps-guard}"
ALLOW_NONROOT="${VPSG_INSTALL_ALLOW_NONROOT:-0}"

need_root() { [[ "$ALLOW_NONROOT" == 1 ]] || [[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "请使用 sudo ./install.sh" >&2; exit 1; }; }

_secure_install_dir() {
  local path="$1" mode="${2:-700}" uid
  assert_no_symlink_components "$path" || return $?
  if [[ -e "$path" || -L "$path" ]]; then
    [[ -d "$path" && ! -L "$path" ]] || { echo "拒绝不可信安装目录: $path" >&2; return 70; }
  else
    mkdir -p -- "$path" || return 40
  fi
  [[ -d "$path" && ! -L "$path" ]] || return 70
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    uid="$(stat -c '%u' "$path" 2>/dev/null || echo -1)"
    [[ "$uid" == 0 ]] || { echo "root 安装拒绝使用非 root 所有的目录: $path" >&2; return 70; }
  fi
  chmod "$mode" "$path" 2>/dev/null || return 40
}

_assert_secure_parent() {
  local path="$1" parent uid
  parent="$(dirname "$path")"
  assert_no_symlink_components "$parent" || return $?
  [[ -d "$parent" && ! -L "$parent" ]] || { echo "安装路径父目录不可信: $parent" >&2; return 70; }
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    uid="$(stat -c '%u' "$parent" 2>/dev/null || echo -1)"
    [[ "$uid" == 0 ]] || { echo "root 安装拒绝使用非 root 所有的父目录: $parent" >&2; return 70; }
  fi
}

assert_install_path() {
  local p="$1" n; n="$(path_normalize_lexical "$p")" || return 1
  [[ "$n" == "$p" ]] || { echo "安装路径必须为已规范化绝对路径: $p -> $n" >&2; return 1; }
  _path_is_dangerous_root "$n" && { echo "拒绝危险安装路径: $n" >&2; return 1; }
  return 0
}
validate_paths() {
  local p; for p in "$DEST" "$STATE_DIR" "$ETC_DIR" "$LOG_DIR"; do assert_install_path "$p" || exit 70; done
  [[ "$LINK" == /* ]] || { echo "命令链接必须是绝对路径" >&2; exit 70; }
  local nd nl target ntarget
  nd="$(path_normalize_lexical "$DEST")"; nl="$(path_normalize_lexical "$LINK")"
  [[ "$nl" != "$nd" && "$nl" != "$nd"/* ]] || { echo "命令链接不能位于程序目录内部: $LINK" >&2; exit 70; }
  if [[ -L "$LINK" ]]; then
    target="$(readlink "$LINK")" || exit 70
    [[ "$target" == /* ]] || target="$(dirname "$LINK")/$target"
    ntarget="$(path_normalize_lexical "$target")" || exit 70
    [[ "$ntarget" == "$nd/bin/vpsg" ]] || { echo "拒绝覆盖不属于 VPS Guard 的现有命令链接: $LINK -> $target" >&2; exit 70; }
  elif [[ -e "$LINK" ]]; then
    echo "拒绝覆盖现有普通文件/目录: $LINK" >&2; exit 70
  fi
  [[ ! -L "$DEST" && ! -L "$STATE_DIR" && ! -L "$ETC_DIR" && ! -L "$LOG_DIR" ]] || { echo "拒绝把关键安装目录作为符号链接使用" >&2; exit 70; }
}

stage_source() {
  local parent tmp
  parent="$(dirname "$DEST")"
  assert_no_symlink_components "$parent" || return $?
  mkdir -p -- "$parent" || return 40
  _assert_secure_parent "$DEST" || return $?
  tmp="$(mktemp -d "$parent/.vps-guard.new.XXXXXX")"
  cp -a "$SRC"/. "$tmp"/; rm -rf -- "$tmp/.git" 2>/dev/null || true
  find "$tmp" -type d -exec chmod 755 {} +
  find "$tmp" -type f -name '*.sh' -exec chmod 755 {} +
  chmod 755 "$tmp/bin/vpsg"
  local f; while IFS= read -r -d '' f; do bash -n "$f"; done < <(find "$tmp" -type f -name '*.sh' -print0)
  bash -n "$tmp/bin/vpsg"; VPSG_ROOT="$tmp" bash "$tmp/bin/vpsg" --version >/dev/null
  printf '%s\n' "$tmp"
}

_prepare_runtime_dirs() {
  _secure_install_dir "$STATE_DIR" 700 || return $?
  _secure_install_dir "$STATE_DIR/backups" 700 || return $?
  _secure_install_dir "$STATE_DIR/install-backups" 700 || return $?
  _secure_install_dir "$ETC_DIR" 755 || return $?
  _secure_install_dir "$LOG_DIR" 755 || return $?
}

_restore_program_after_failure() {
  local old="${1:-}"
  [[ ! -e "$DEST" ]] || safe_rm_rf_within "$DEST" "$(dirname "$DEST")" >/dev/null 2>&1 || true
  if [[ -n "$old" && -d "$old" ]]; then
    mv -- "$old" "$DEST" 2>/dev/null || true
  elif [[ -L "$LINK" && "$(readlink "$LINK" 2>/dev/null || true)" == "$DEST/bin/vpsg" ]]; then
    rm -f -- "$LINK"
  fi
}

_install_stage() {
  local staged="$1" stamp backup old="" version link_parent
  _prepare_runtime_dirs
  stamp="$(date +%Y%m%d-%H%M%S)-$$"; backup="$STATE_DIR/install-backups/$stamp"; _secure_install_dir "$backup" 700 || return $?
  if [[ -d "$DEST" ]]; then
    cp -a "$DEST" "$backup/previous"
    old="${DEST}.old.$$"
    [[ ! -e "$old" ]] || safe_rm_rf_within "$old" "$(dirname "$DEST")"
    mv -- "$DEST" "$old"
  fi
  if ! mv -- "$staged" "$DEST"; then
    [[ -z "$old" || ! -d "$old" ]] || mv -- "$old" "$DEST" 2>/dev/null || true
    return 40
  fi
  link_parent="$(dirname "$LINK")"
  if ! assert_no_symlink_components "$link_parent"; then _restore_program_after_failure "$old"; return 70; fi
  if ! mkdir -p -- "$link_parent"; then _restore_program_after_failure "$old"; return 40; fi
  if ! _assert_secure_parent "$LINK"; then _restore_program_after_failure "$old"; return 70; fi
  if ! ln -sfn -- "$DEST/bin/vpsg" "$LINK"; then _restore_program_after_failure "$old"; return 40; fi
  if ! version="$(VPSG_ROOT="$DEST" bash "$DEST/bin/vpsg" --version 2>/dev/null)"; then
    _restore_program_after_failure "$old"
    return 50
  fi
  [[ -z "$old" || ! -d "$old" ]] || safe_rm_rf_within "$old" "$(dirname "$DEST")" || true
  if ! printf '%s\n' "$stamp" | atomic_write_file "$STATE_DIR/install-current" 600; then
    warn "程序已安装，但 install-current 元数据写入失败；历史备份仍保留。"
  fi
  echo "VPS Guard $version 安装完成。运行: vpsg"
}

rollback_program() {
  _prepare_runtime_dirs
  local backup="${1:-}" staged old version nbackup nroot
  if [[ -z "$backup" ]]; then
    backup="$(find "$STATE_DIR/install-backups" -mindepth 2 -maxdepth 2 -type d -name previous -printf '%h\n' 2>/dev/null | LC_ALL=C sort -r | head -1)"
    [[ -n "$backup" ]] && backup="$backup/previous"
  fi
  [[ -n "$backup" ]] || { echo "没有可用的程序版本回滚点" >&2; return 20; }
  nbackup="$(path_normalize_lexical "$backup")" || return 70
  nroot="$(path_normalize_lexical "$STATE_DIR/install-backups")" || return 70
  [[ "$nbackup" == "$backup" && "$nbackup" == "$nroot"/*/previous ]] || { echo "拒绝不属于 VPS Guard install-backups 的回滚点: $backup" >&2; return 70; }
  local stamp_dir; stamp_dir="$(dirname "$backup")"
  [[ -d "$nroot" && ! -L "$nroot" && -d "$stamp_dir" && ! -L "$stamp_dir" && -d "$backup" && ! -L "$backup" && -f "$backup/bin/vpsg" && ! -L "$backup/bin/vpsg" ]] || { echo "没有可信的程序版本回滚点" >&2; return 20; }
  staged="$(mktemp -d "$(dirname "$DEST")/.vps-guard.rollback.XXXXXX")"; cp -a "$backup"/. "$staged"/
  VPSG_ROOT="$staged" bash "$staged/bin/vpsg" --version >/dev/null || { safe_rm_rf_within "$staged" "$(dirname "$DEST")"; return 50; }
  old="${DEST}.old.$$"
  [[ ! -d "$DEST" ]] || mv -- "$DEST" "$old"
  if ! mv -- "$staged" "$DEST"; then [[ ! -d "$old" ]] || mv -- "$old" "$DEST"; return 40; fi
  if ! _assert_secure_parent "$LINK"; then _restore_program_after_failure "$old"; return 70; fi
  if ! ln -sfn -- "$DEST/bin/vpsg" "$LINK"; then _restore_program_after_failure "$old"; return 40; fi
  if ! version="$(VPSG_ROOT="$DEST" bash "$DEST/bin/vpsg" --version 2>/dev/null)"; then _restore_program_after_failure "$old"; return 50; fi
  [[ ! -d "$old" ]] || safe_rm_rf_within "$old" "$(dirname "$DEST")" || true
  echo "程序已回滚到 VPS Guard $version；服务器安全配置和运行数据未回滚。"
}

main() {
  need_root; validate_paths
  case "${1:-}" in
    --rollback) rollback_program "${2:-}" ;;
    "") local staged; staged="$(stage_source)"; trap '[[ -z "${staged:-}" || ! -d "$staged" ]] || safe_rm_rf_within "$staged" "$(dirname "$DEST")" >/dev/null 2>&1 || true' EXIT; _install_stage "$staged"; staged="" ;;
    *) echo "用法: sudo ./install.sh [--rollback [backup/previous]]" >&2; return 64 ;;
  esac
}
main "$@"
