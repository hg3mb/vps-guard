#!/usr/bin/env bash

platform_detect() {
  [[ -r /etc/os-release ]] || return 1
  # shellcheck disable=SC1091
  . /etc/os-release
  VPSG_OS_ID="${ID:-unknown}"
  VPSG_OS_VERSION="${VERSION_ID:-unknown}"
  VPSG_OS_PRETTY="${PRETTY_NAME:-$VPSG_OS_ID $VPSG_OS_VERSION}"
  export VPSG_OS_ID VPSG_OS_VERSION VPSG_OS_PRETTY
}

platform_supported() {
  platform_detect || return 1
  [[ "$VPSG_OS_ID" == "debian" || "$VPSG_OS_ID" == "ubuntu" ]]
}

apt_install() {
  require_root || return 1
  DEBIAN_FRONTEND=noninteractive apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

ssh_connection_port() {
  local p=""
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    p="$(awk '{print $4}' <<<"$SSH_CONNECTION")"
    valid_port "$p" && { printf '%s\n' "$p"; return 0; }
  fi
  return 1
}

ssh_configured_ports() {
  have sshd || return 20
  sshd -T 2>/dev/null | awk '$1=="port" && $2 ~ /^[0-9]+$/ {print $2}' | sort -nu
}

ssh_listening_ports() {
  local ports=""
  if have ss; then
    ports="$(ss -H -ltnp 2>/dev/null | awk '/sshd|ssh\.socket/ {split($4,a,":"); p=a[length(a)]; if (p ~ /^[0-9]+$/) print p}' | sort -nu)"
  fi
  if [[ -z "$ports" ]]; then ports="$(ssh_configured_ports 2>/dev/null || true)"; fi
  printf '%s\n' "$ports" | sed '/^$/d'
}

ssh_effective_primary_port() {
  local ports count
  ports="$(ssh_configured_ports 2>/dev/null || true)"
  count="$(grep -c . <<<"$ports" || true)"
  if [[ -n "$ports" && "$count" == 1 ]]; then printf '%s\n' "$ports"; return 0; fi
  ports="$(ssh_listening_ports 2>/dev/null || true)"
  count="$(grep -c . <<<"$ports" || true)"
  if [[ -n "$ports" && "$count" == 1 ]]; then printf '%s\n' "$ports"; return 0; fi
  return 1
}

# Management port prefers the current SSH connection. This is intentionally
# different from ssh_effective_primary_port(): while changing SSH settings the
# old connection must remain protected until a new login works.
ssh_primary_port() {
  local p
  if p="$(ssh_connection_port 2>/dev/null)"; then printf '%s\n' "$p"; return 0; fi
  ssh_effective_primary_port
}

memory_mb() { awk '/MemTotal:/ {printf "%d\n", $2/1024}' /proc/meminfo; }
root_free_mb() { df -Pm / | awk 'NR==2 {print $4}'; }
