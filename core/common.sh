#!/usr/bin/env bash

VPSG_NAME="VPS Guard"
VPSG_VERSION="0.2.0"
VPSG_ROOT="${VPSG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
VPSG_STATE_DIR="${VPSG_STATE_DIR:-/var/lib/vps-guard}"
VPSG_BACKUP_DIR="${VPSG_BACKUP_DIR:-${VPSG_STATE_DIR}/backups}"
VPSG_LOG_DIR="${VPSG_LOG_DIR:-/var/log/vps-guard}"
VPSG_ETC_DIR="${VPSG_ETC_DIR:-/etc/vps-guard}"
VPSG_ASSUME_YES="${VPSG_ASSUME_YES:-0}"

supports_color() { [[ -t 1 && "${NO_COLOR:-}" == "" ]]; }
if supports_color; then
  C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_BLUE='\033[34m'; C_BOLD='\033[1m'; C_RESET='\033[0m'
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''; C_RESET=''
fi

info()  { printf "%b[INFO]%b %s\n" "$C_BLUE" "$C_RESET" "$*"; }
ok()    { printf "%b[ OK ]%b %s\n" "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf "%b[WARN]%b %s\n" "$C_YELLOW" "$C_RESET" "$*" >&2; }
error() { printf "%b[ERR ]%b %s\n" "$C_RED" "$C_RESET" "$*" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    error "此操作需要 root 权限，请使用 sudo vpsg ..."
    return 1
  fi
}

ensure_runtime_dirs() {
  mkdir -p "$VPSG_STATE_DIR" "$VPSG_BACKUP_DIR" "$VPSG_LOG_DIR" "$VPSG_ETC_DIR"
  chmod 700 "$VPSG_STATE_DIR" "$VPSG_BACKUP_DIR" 2>/dev/null || true
}

log_event() {
  local level="$1"; shift
  if [[ -w "$VPSG_LOG_DIR" || ( ! -e "$VPSG_LOG_DIR" && ${EUID:-$(id -u)} -eq 0 ) ]]; then
    ensure_runtime_dirs
    printf '%s\t%s\t%s\n' "$(date -Is)" "$level" "$*" >> "$VPSG_LOG_DIR/operations.log"
  fi
}

confirm() {
  local prompt="${1:-确认继续？}"
  if [[ "$VPSG_ASSUME_YES" == "1" ]]; then return 0; fi
  local ans
  read -r -p "$prompt [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

parse_yes_flag() {
  local a
  for a in "$@"; do
    [[ "$a" == "--yes" || "$a" == "-y" ]] && VPSG_ASSUME_YES=1
  done
}

valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }

managed_backup() {
  local file="$1" tag="$2"
  ensure_runtime_dirs
  local dir="$VPSG_BACKUP_DIR/$tag"
  mkdir -p "$dir"
  local stamp="$(date +%Y%m%d-%H%M%S)"
  local out="$dir/${stamp}.bak"
  if [[ -e "$file" ]]; then
    cp -a "$file" "$out"
  else
    : > "$out.absent"
  fi
  printf '%s\n' "$out"
}
