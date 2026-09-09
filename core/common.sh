#!/usr/bin/env bash

VPSG_NAME="VPS Guard"
VPSG_VERSION="0.4.0"
VPSG_ROOT="${VPSG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
VPSG_STATE_DIR="${VPSG_STATE_DIR:-/var/lib/vps-guard}"
VPSG_BACKUP_DIR="${VPSG_BACKUP_DIR:-${VPSG_STATE_DIR}/backups}"
VPSG_LOG_DIR="${VPSG_LOG_DIR:-/var/log/vps-guard}"
VPSG_ETC_DIR="${VPSG_ETC_DIR:-/etc/vps-guard}"
# System paths are overridable for isolated regression tests and chroot-like
# environments. Production defaults remain the normal Debian/Ubuntu paths.
VPSG_SYSTEMD_DIR="${VPSG_SYSTEMD_DIR:-/etc/systemd/system}"
VPSG_SSH_CONFIG_DIR="${VPSG_SSH_CONFIG_DIR:-/etc/ssh/sshd_config.d}"
VPSG_SSH_MAIN_CONFIG="${VPSG_SSH_MAIN_CONFIG:-/etc/ssh/sshd_config}"
VPSG_UFW_DIR="${VPSG_UFW_DIR:-/etc/ufw}"
VPSG_UFW_DEFAULT="${VPSG_UFW_DEFAULT:-/etc/default/ufw}"
VPSG_FAIL2BAN_JAIL_DIR="${VPSG_FAIL2BAN_JAIL_DIR:-/etc/fail2ban/jail.d}"
VPSG_APT_CONF_DIR="${VPSG_APT_CONF_DIR:-/etc/apt/apt.conf.d}"
VPSG_APT_KEYRINGS_DIR="${VPSG_APT_KEYRINGS_DIR:-/etc/apt/keyrings}"
VPSG_APT_SOURCES_DIR="${VPSG_APT_SOURCES_DIR:-/etc/apt/sources.list.d}"
VPSG_SYSCTL_DIR="${VPSG_SYSCTL_DIR:-/etc/sysctl.d}"
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

_ensure_runtime_dir() {
  local path="$1" mode="$2" uid
  [[ -n "$path" && "$path" == /* ]] || return 64
  assert_no_symlink_components "$path" || return $?
  [[ ! -L "$path" ]] || { error "拒绝使用符号链接运行目录: $path"; return 70; }
  if [[ -e "$path" && ! -d "$path" ]]; then error "运行路径存在但不是目录: $path"; return 70; fi
  mkdir -p -- "$path" || return 40
  [[ -d "$path" && ! -L "$path" ]] || return 70
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    uid="$(stat -c '%u' "$path" 2>/dev/null || echo -1)"
    [[ "$uid" == 0 ]] || { error "root 操作拒绝使用非 root 所有的运行目录: $path"; return 70; }
  fi
  chmod "$mode" "$path" 2>/dev/null || return 40
}

ensure_runtime_dirs() {
  _ensure_runtime_dir "$VPSG_STATE_DIR" 700 || return $?
  _ensure_runtime_dir "$VPSG_BACKUP_DIR" 700 || return $?
  _ensure_runtime_dir "$VPSG_LOG_DIR" 750 || return $?
  _ensure_runtime_dir "$VPSG_ETC_DIR" 755 || return $?
}

log_event() {
  local level="$1"; shift
  if [[ -w "$VPSG_LOG_DIR" || ( ! -e "$VPSG_LOG_DIR" && ${EUID:-$(id -u)} -eq 0 ) ]]; then
    ensure_runtime_dirs || return 0
    printf '%s\t%s\t%s\n' "$(date -Is)" "$level" "$*" >> "$VPSG_LOG_DIR/operations.log" 2>/dev/null || true
  fi
}

confirm() {
  local prompt="${1:-确认继续？}" ans
  [[ "$VPSG_ASSUME_YES" == 1 ]] && return 0
  read -r -p "$prompt [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

parse_yes_flag() {
  local a
  for a in "$@"; do [[ "$a" == --yes || "$a" == -y ]] && VPSG_ASSUME_YES=1; done
}

valid_port() { [[ "${1:-}" =~ ^[0-9]+$ ]] && ((10#${1} >= 1 && 10#${1} <= 65535)); }

# Count key-like authorized_keys entries, including lines with OpenSSH options
# before the key type. This is intentionally a syntactic readiness check, not
# proof that sshd will accept a future login.
authorized_keys_count_file() {
  local file="${1:-}"
  [[ -f "$file" && ! -L "$file" ]] || { echo 0; return 0; }
  awk '
    /^[[:space:]]*($|#)/ { next }
    {
      for (i=1; i<NF; i++) {
        if ($i ~ /^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)$/ && $(i+1) ~ /^[A-Za-z0-9+\/=]+$/) {
          n++; break
        }
      }
    }
    END { print n+0 }
  ' "$file"
}

# Quote one argument for a systemd unit directive such as ExecStart= or
# ReadWritePaths=. Newlines are rejected; backslash and double quote are escaped.
systemd_quote_arg() {
  local s="${1:-}"
  [[ -n "$s" && "$s" != *$'\n'* && "$s" != *$'\r'* ]] || return 64
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

# Download a remote Bash script to a regular local file without executing it.
# This is the common safety boundary for optional third-party integrations.
# The caller still decides whether/under which user to execute the script.
download_bash_script_checked() {
  local url="${1:-}" dest="${2:-}" max_bytes="${3:-5242880}" size
  [[ "$url" == https://* && "$url" != *$'\n'* && "$url" != *$'\r'* && -n "$dest" ]] || return 64
  [[ "$max_bytes" =~ ^[0-9]+$ && "$max_bytes" -ge 1024 ]] || return 64
  have curl || return 20
  # Never let curl follow a pre-existing symlink when this helper runs as root.
  [[ ! -L "$dest" ]] || { error "拒绝把远程脚本写入符号链接目标: $dest"; return 70; }
  [[ ! -e "$dest" || -f "$dest" ]] || return 70
  if ! curl -fL --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 15 --max-time 120 --retry 2 --retry-delay 1 "$url" -o "$dest"; then
    rm -f -- "$dest"; return 40
  fi
  [[ -s "$dest" && ! -L "$dest" ]] || { rm -f -- "$dest"; return 40; }
  size="$(stat -c '%s' "$dest" 2>/dev/null || echo 0)"
  [[ "$size" =~ ^[0-9]+$ && "$size" -le "$max_bytes" ]] || { rm -f -- "$dest"; error "远程脚本大小异常，拒绝继续（${size} bytes）"; return 40; }
  if LC_ALL=C grep -Eiq '<!doctype|<html|cloudflare|just a moment|access denied' "$dest"; then
    rm -f -- "$dest"; error "下载内容看起来是网页/错误页而不是 Bash 脚本"; return 40
  fi
  if ! /bin/bash -n "$dest"; then rm -f -- "$dest"; error "远程脚本未通过 bash -n 语法检查"; return 50; fi
  chmod 600 "$dest" 2>/dev/null || { rm -f -- "$dest"; return 40; }
}

show_downloaded_script_summary() {
  local file="${1:-}" url="${2:-}" license="${3:-unknown}"
  [[ -f "$file" ]] || return 64
  printf '来源: %s\n许可证/上游声明: %s\nSHA-256: %s\n大小: %s bytes\n脚本预览:\n' \
    "$url" "$license" "$(sha256sum "$file" | awk '{print $1}')" "$(stat -c '%s' "$file" 2>/dev/null || echo '?')"
  sed -n '1,14p' "$file"
}

# Lexically normalize without following symlinks. Destructive paths must treat
# /var/lib/.. as /var instead of a harmless-looking child path.
path_normalize_lexical() {
  local input="${1:-}" part out oldifs
  local -a _parts=()
  [[ -n "$input" ]] || return 64
  [[ "$input" == /* ]] || input="$PWD/$input"
  oldifs="$IFS"; IFS='/'; read -r -a _parts <<<"${input#/}"; IFS="$oldifs"
  local -a stack=()
  for part in "${_parts[@]}"; do
    case "$part" in
      ''|.) ;;
      ..) ((${#stack[@]} > 0)) && unset "stack[$((${#stack[@]}-1))]" ;;
      *) stack+=("$part") ;;
    esac
  done
  ((${#stack[@]})) || { printf '/\n'; return 0; }
  out="$(IFS=/; printf '%s' "${stack[*]}")"
  printf '/%s\n' "$out"
}

_path_is_dangerous_root() {
  case "$1" in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib32|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var) return 0 ;;
    *) return 1 ;;
  esac
}

# Return success when any *existing* component in an absolute path is a
# symbolic link. Security-sensitive root operations use this before mkdir/rm
# so an apparently safe lexical path cannot be redirected through an ancestor
# such as /safe/state -> /etc. Missing tail components are fine; once a
# component is missing no deeper component can exist yet.
path_has_symlink_component() {
  local input="${1:-}" n current="" part
  [[ -n "$input" ]] || return 64
  n="$(path_normalize_lexical "$input")" || return $?
  [[ "$n" == /* ]] || return 64
  [[ "$n" == / ]] && return 1
  local -a parts=()
  IFS='/' read -r -a parts <<<"${n#/}"
  for part in "${parts[@]}"; do
    current="$current/$part"
    [[ -L "$current" ]] && return 0
    [[ -e "$current" ]] || return 1
  done
  return 1
}

assert_no_symlink_components() {
  local path="${1:-}" rc
  if path_has_symlink_component "$path"; then
    error "拒绝通过符号链接路径执行高权限文件操作: $path"
    return 70
  else
    rc=$?
  fi
  [[ $rc -eq 1 ]] && return 0
  return "$rc"
}

vpsg_file_is_managed() {
  local file="${1:-}"
  [[ -f "$file" && ! -L "$file" ]] || return 1
  grep -Fqx '# Managed by VPS Guard' "$file" 2>/dev/null
}

safe_rm_rf_within() {
  local path="${1:-}" base="${2:-}" npath nbase parent
  [[ -n "$path" && -n "$base" ]] || return 64
  npath="$(path_normalize_lexical "$path")" || return $?
  nbase="$(path_normalize_lexical "$base")" || return $?
  _path_is_dangerous_root "$npath" && { error "拒绝删除危险路径: $npath"; return 70; }
  [[ "$npath" == "$nbase"/* ]] || { error "拒绝删除不在允许目录内的路径: $npath (base=$nbase)"; return 70; }

  # Lexical containment alone is insufficient when an ancestor is a symlink:
  # /safe/base/link/child may actually resolve outside /safe/base. Reject any
  # symlink in the trusted base or in the target's parent path. The target leaf
  # itself may be a symlink; rm -rf removes that link rather than following it.
  assert_no_symlink_components "$nbase" || return $?
  parent="$(dirname "$npath")"
  assert_no_symlink_components "$parent" || return $?

  rm -rf -- "$npath"
}

# Replace one regular file atomically on the same filesystem. Content is stdin.
atomic_write_file() {
  local dest="${1:-}" mode="${2:-600}" dir base tmp
  [[ -n "$dest" ]] || return 64
  dir="$(dirname "$dest")"; base="$(basename "$dest")"
  assert_no_symlink_components "$dir" || return $?
  mkdir -p "$dir" || return 40
  tmp="$(mktemp "$dir/.${base}.tmp.XXXXXX")" || return 40
  if ! cat > "$tmp"; then rm -f -- "$tmp"; return 40; fi
  chmod "$mode" "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 40; }
  if ! mv -f -- "$tmp" "$dest"; then rm -f -- "$tmp"; return 40; fi
}

# Atomic rename protects readers from partial files, but a safety-critical state
# record also needs a persistence barrier before the caller can rely on it after
# a sudden power loss. Debian/Ubuntu coreutils provides `sync -f`, which issues
# a filesystem-level sync for the filesystem containing the path. Keep this as
# a separate primitive so ordinary UI/config writes do not pay the cost.
durable_sync_path() {
  local path="${1:-}"
  [[ -n "$path" && "$path" == /* ]] || return 64
  have sync || { error "缺少 coreutils sync，无法确认关键状态已持久化"; return 20; }
  sync -f -- "$path" >/dev/null 2>&1 || return 40
}

atomic_write_file_durable() {
  local dest="${1:-}" mode="${2:-600}"
  atomic_write_file "$dest" "$mode" || return $?
  durable_sync_path "$dest"
}

# Same as atomic_write_file, but ownership is assigned before the inode becomes
# visible at its final path. Useful for authorized_keys of non-root users.
atomic_write_file_owned() {
  local dest="${1:-}" mode="${2:-600}" uid="${3:-}" gid="${4:-}" dir base tmp
  [[ -n "$dest" && "$uid" =~ ^[0-9]+$ && "$gid" =~ ^[0-9]+$ ]] || return 64
  dir="$(dirname "$dest")"; base="$(basename "$dest")"
  assert_no_symlink_components "$dir" || return $?
  mkdir -p "$dir" || return 40
  tmp="$(mktemp "$dir/.${base}.tmp.XXXXXX")" || return 40
  if ! cat > "$tmp"; then rm -f -- "$tmp"; return 40; fi
  chmod "$mode" "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 40; }
  chown "$uid:$gid" "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 40; }
  if ! mv -f -- "$tmp" "$dest"; then rm -f -- "$tmp"; return 40; fi
}

atomic_copy_file() {
  local src="${1:-}" dest="${2:-}" mode="${3:-}"
  [[ -f "$src" && -n "$dest" ]] || return 64
  [[ -n "$mode" ]] || mode="$(stat -c '%a' "$src" 2>/dev/null || echo 600)"
  atomic_write_file "$dest" "$mode" < "$src"
}

managed_backup() {
  local file="$1" tag="$2" dir stamp out
  ensure_runtime_dirs || return 40
  dir="$VPSG_BACKUP_DIR/$tag"; mkdir -p "$dir" || return 40; chmod 700 "$dir" 2>/dev/null || true
  stamp="$(date +%Y%m%d-%H%M%S)-$$"; out="$dir/${stamp}.bak"
  if [[ -e "$file" ]]; then cp -a -- "$file" "$out" || return 40; else : > "$out.absent" || return 40; fi
  printf '%s\n' "$out"
}
