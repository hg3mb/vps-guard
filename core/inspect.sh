#!/usr/bin/env bash

inspect_scope() {
  local addr="${1#[}"; addr="${addr%]}"
  case "$addr" in
    0.0.0.0|::|\*) echo wildcard ;;
    127.*|::1) echo loopback ;;
    10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|169.254.*|fc*|fd*|fe80:*) echo private ;;
    *) echo specific ;;
  esac
}

inspect_listeners() {
  have ss || return 20
  local line proto local_ep addr port process scope
  ss -H -lntup 2>/dev/null | while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    # ss columns: Netid State Recv-Q Send-Q Local:Port Peer:Port Process
    read -r proto _ _ _ local_ep _ _ <<<"$line"
    [[ -n "$local_ep" ]] || continue
    port="${local_ep##*:}"
    addr="${local_ep%:*}"
    addr="${addr#[}"; addr="${addr%]}"
    [[ "$port" =~ ^[0-9]+$ ]] || continue
    process="$(sed -n 's/.*users:(//p' <<<"$line" | sed 's/))$//' | sed 's/[[:space:]]\+/ /g')"
    [[ -n "$process" ]] || process="unknown"
    scope="$(inspect_scope "$addr")"
    printf '%s\t%s\t%s\t%s\t%s\n' "$proto" "$addr" "$port" "$scope" "$process"
  done | sort -t $'\t' -k3,3n -k1,1 -u
}

inspect_docker_ports() {
  have docker || return 0
  docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null | while IFS=$'\t' read -r name ports; do
    [[ -n "$name" ]] || continue
    IFS=',' read -ra entries <<<"$ports"
    local e bind hp cp proto scope
    for e in "${entries[@]}"; do
      e="${e# }"; e="${e% }"
      [[ "$e" == *"->"* ]] || continue
      proto="${e##*/}"; e="${e%/*}"
      cp="${e##*->}"; e="${e%->*}"
      hp="${e##*:}"; bind="${e%:*}"
      bind="${bind#[}"; bind="${bind%]}"
      [[ "$hp" =~ ^[0-9]+$ ]] || continue
      scope="$(inspect_scope "$bind")"
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$proto" "$bind" "$hp" "$cp" "$scope"
    done
  done | sort -t $'\t' -k4,4n -u
}

inspect_ufw_active() { have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; }

inspect_ufw_port_policy() {
  local port="$1" proto="${2:-tcp}"
  if ! have ufw; then echo unavailable; return 0; fi
  if ! inspect_ufw_active; then echo inactive; return 0; fi
  local row
  row="$(ufw status 2>/dev/null | grep -E "^${port}(/${proto})?([[:space:]]|$)" | head -1 || true)"
  if grep -q 'ALLOW' <<<"$row"; then echo allow
  elif grep -q 'DENY\|REJECT' <<<"$row"; then echo deny
  else echo default; fi
}

inspect_users() {
  getent passwd | awk -F: '($3==0 || $3>=1000) && $7 !~ /(nologin|false)$/ {print $1 "\t" $3 "\t" $6 "\t" $7}' | sort
}

inspect_sudo_access() {
  local g members
  for g in sudo wheel admin; do
    if getent group "$g" >/dev/null 2>&1; then
      members="$(getent group "$g" | awk -F: '{print $4}')"
      printf 'group\t%s\t%s\n' "$g" "$members"
    fi
  done
  if [[ -r /etc/sudoers ]]; then printf 'file\t/etc/sudoers\t%s\n' "$(sha256sum /etc/sudoers | awk '{print $1}')"; fi
  if [[ -d /etc/sudoers.d ]]; then
    find /etc/sudoers.d -maxdepth 1 -type f -print0 2>/dev/null | sort -z | while IFS= read -r -d '' f; do
      printf 'file\t%s\t%s\n' "$f" "$(sha256sum "$f" | awk '{print $1}')"
    done
  fi
}

inspect_authorized_keys() {
  local f
  for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    [[ -f "$f" ]] || continue
    printf '%s\t%s\t%s\n' "$f" "$(wc -l < "$f" | tr -d ' ')" "$(sha256sum "$f" | awk '{print $1}')"
  done | sort
}

inspect_services() {
  have systemctl || return 0
  systemctl list-unit-files --type=service --state=enabled --no-legend --no-pager 2>/dev/null | awk '{print $1}' | sort
}

inspect_docker_state() {
  have docker || return 0
  docker ps --format '{{.Names}}\t{{.Image}}\t{{.Ports}}' 2>/dev/null | sort
}

inspect_firewall_state() {
  if have ufw; then ufw status verbose 2>/dev/null | sed 's/[[:space:]]\+$//' || true
  elif have nft; then nft list ruleset 2>/dev/null | sed '/^[[:space:]]*counter packets/d' || true
  else echo 'no-supported-firewall-detected'; fi
}

inspect_ssh_effective() {
  have sshd || return 0
  sshd -T 2>/dev/null | awk '$1 ~ /^(port|listenaddress|permitrootlogin|passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication|maxauthtries|logingracetime|allowusers|allowgroups|denyusers|denygroups)$/ {print}' | sort
}

inspect_cron_hashes() {
  local f
  for f in /etc/crontab /etc/cron.d/*; do
    [[ -f "$f" ]] || continue
    printf '%s\t%s\n' "$f" "$(sha256sum "$f" | awk '{print $1}')"
  done | sort
}

inspect_sysctl_security() {
  local k
  for k in \
    net.ipv4.ip_forward net.ipv6.conf.all.forwarding \
    net.ipv4.conf.all.accept_redirects net.ipv4.conf.default.accept_redirects \
    net.ipv4.conf.all.send_redirects net.ipv4.conf.all.rp_filter \
    kernel.kptr_restrict kernel.dmesg_restrict fs.protected_hardlinks fs.protected_symlinks; do
    printf '%s=%s\n' "$k" "$(sysctl -n "$k" 2>/dev/null || echo unavailable)"
  done
}

snapshot_capture() {
  local out="$1"
  mkdir -p "$out"
  inspect_listeners > "$out/listeners.tsv" 2>/dev/null || :
  inspect_docker_ports > "$out/docker-ports.tsv" 2>/dev/null || :
  inspect_users > "$out/users.tsv" 2>/dev/null || :
  inspect_sudo_access > "$out/sudo.tsv" 2>/dev/null || :
  inspect_authorized_keys > "$out/authorized-keys.tsv" 2>/dev/null || :
  inspect_services > "$out/services.txt" 2>/dev/null || :
  inspect_docker_state > "$out/docker.tsv" 2>/dev/null || :
  inspect_firewall_state > "$out/firewall.txt" 2>/dev/null || :
  inspect_ssh_effective > "$out/ssh.txt" 2>/dev/null || :
  inspect_cron_hashes > "$out/cron.tsv" 2>/dev/null || :
  inspect_sysctl_security > "$out/sysctl.txt" 2>/dev/null || :
  cat > "$out/manifest" <<EOF_MANIFEST
schema=1
created=$(date -Is)
hostname=$(hostname 2>/dev/null || echo unknown)
kernel=$(uname -r)
vpsg_version=$VPSG_VERSION
EOF_MANIFEST
}
