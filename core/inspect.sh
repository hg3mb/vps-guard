#!/usr/bin/env bash

inspect_scope() {
  local addr="${1:-}" b
  addr="${addr#[}"; addr="${addr%]}"; addr="${addr,,}"
  # Normalize IPv4-mapped IPv6 forms used by some runtimes.
  [[ "$addr" == ::ffff:*.*.*.* ]] && addr="${addr#::ffff:}"
  case "$addr" in
    ''|0.0.0.0|::|\*) echo wildcard; return 0 ;;
    127.*|::1) echo loopback; return 0 ;;
    10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|169.254.*|fc*|fd*|fe80:*) echo private; return 0 ;;
  esac
  if [[ "$addr" =~ ^100\.([0-9]{1,3})\. ]]; then
    b="${BASH_REMATCH[1]}"
    if ((10#$b >= 64 && 10#$b <= 127)); then echo private; return 0; fi
  fi
  echo specific
}

inspect_listeners() {
  have ss || return 20
  local line proto local_ep addr port process scope
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    # ss: Netid State Recv-Q Send-Q Local:Port Peer:Port Process
    read -r proto _ _ _ local_ep _ <<<"$line"
    [[ -n "$local_ep" ]] || continue
    port="${local_ep##*:}"; addr="${local_ep%:*}"; addr="${addr#[}"; addr="${addr%]}"
    [[ "$port" =~ ^[0-9]+$ ]] || continue
    # Keep only stable process names. PIDs/file descriptors in raw `ss -p`
    # output change across restarts and would otherwise create false Drift.
    process="$(grep -oE '\("[^"]+"' <<<"$line" 2>/dev/null | sed 's/^("//; s/"$//' | LC_ALL=C sort -u | paste -sd, -)"
    [[ -n "$process" ]] || process=unknown
    scope="$(inspect_scope "$addr")"
    printf '%s\t%s\t%s\t%s\t%s\n' "$proto" "$addr" "$port" "$scope" "$process"
  done < <(ss -H -lntup 2>/dev/null) | LC_ALL=C sort -t $'\t' -k3,3n -k1,1 -k2,2 -u
}

inspect_docker_visibility() {
  if ! have docker; then echo absent; return 0; fi
  if docker info >/dev/null 2>&1; then echo accessible; return 0; fi
  echo restricted
  return 30
}

# container<TAB>proto<TAB>host-ip<TAB>host-port<TAB>container-port<TAB>scope
inspect_docker_ports() {
  have docker || return 0
  docker info >/dev/null 2>&1 || return 30
  local id raw name endpoint host_ip host_port container_port proto scope ids
  ids="$(docker ps -q 2>/dev/null)" || return 30
  [[ -n "$ids" ]] || return 0
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    raw="$(docker inspect --format '{{ $name := .Name }}{{range $p, $bindings := .NetworkSettings.Ports}}{{range $bindings}}{{printf "%s\\t%s\\t%s\\t%s\\n" $name $p .HostIp .HostPort}}{{end}}{{end}}' "$id" 2>/dev/null)" || return 30
    while IFS=$'\t' read -r name endpoint host_ip host_port; do
      [[ -n "$name" && -n "$endpoint" && -n "$host_port" ]] || continue
      name="${name#/}"; proto="${endpoint##*/}"; container_port="${endpoint%/*}"
      [[ "$container_port" =~ ^[0-9]+$ && "$host_port" =~ ^[0-9]+$ ]] || continue
      [[ -n "$host_ip" ]] || host_ip=0.0.0.0
      scope="$(inspect_scope "$host_ip")"
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$proto" "$host_ip" "$host_port" "$container_port" "$scope"
    done <<<"$raw"
  done <<<"$ids" | LC_ALL=C sort -t $'\t' -k4,4n -k2,2 -k3,3 -u
}

inspect_ufw_active() { have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; }
inspect_ufw_port_policy() {
  local port="$1" proto="${2:-tcp}" row
  if ! have ufw; then echo unavailable; return 0; fi
  if ! inspect_ufw_active; then echo inactive; return 0; fi
  row="$(ufw status 2>/dev/null | grep -E "^${port}(/${proto})?([[:space:]]|$)" | head -1 || true)"
  if grep -q 'ALLOW' <<<"$row"; then echo allow
  elif grep -qE 'DENY|REJECT' <<<"$row"; then echo deny
  else echo default; fi
}

inspect_users() {
  getent passwd | awk -F: '($3==0 || $3>=1000) && $7 !~ /(nologin|false)$/ {print $1 "\t" $3 "\t" $6 "\t" $7}' | LC_ALL=C sort
}

inspect_sudo_access() {
  local g members f
  for g in sudo wheel admin; do
    if getent group "$g" >/dev/null 2>&1; then members="$(getent group "$g" | awk -F: '{print $4}')"; printf 'group\t%s\t%s\n' "$g" "$members"; fi
  done
  [[ ! -r /etc/sudoers ]] || printf 'file\t/etc/sudoers\t%s\n' "$(sha256sum /etc/sudoers | awk '{print $1}')"
  if [[ -d /etc/sudoers.d ]]; then
    while IFS= read -r -d '' f; do printf 'file\t%s\t%s\n' "$f" "$(sha256sum "$f" | awk '{print $1}')"; done < <(find /etc/sudoers.d -maxdepth 1 -type f -print0 2>/dev/null | sort -z)
  fi
}

inspect_authorized_keys() {
  local u uid home shell f count
  while IFS=: read -r u _ uid _ _ home shell; do
    [[ "$uid" =~ ^[0-9]+$ ]] || continue
    (( uid == 0 || uid >= 1000 )) || continue
    [[ "$shell" =~ (nologin|false)$ ]] && continue
    [[ -n "$home" && "$home" == /* ]] || continue
    f="$home/.ssh/authorized_keys"
    [[ -f "$f" && ! -L "$f" ]] || continue
    count="$(authorized_keys_count_file "$f")"
    printf '%s\t%s\t%s\n' "$f" "$count" "$(sha256sum "$f" | awk '{print $1}')"
  done < <(getent passwd) | LC_ALL=C sort
}

inspect_services() {
  have systemctl || return 20
  systemctl list-unit-files --type=service --state=enabled --no-legend --no-pager 2>/dev/null | awk '{print $1}' | LC_ALL=C sort
}
inspect_docker_state() {
  have docker || return 0
  docker info >/dev/null 2>&1 || return 30
  # `.Status` contains volatile uptime text (for example `Up 3 hours`). `.State`
  # is the stable lifecycle state and avoids a meaningless Drift every day.
  docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.State}}' 2>/dev/null | LC_ALL=C sort
}
inspect_firewall_state() {
  if have ufw; then ufw status verbose 2>/dev/null | sed 's/[[:space:]]\+$//' || return 20
  elif have nft; then nft list ruleset 2>/dev/null | sed '/^[[:space:]]*counter packets/d' || return 20
  else echo no-supported-firewall-detected; fi
}
inspect_ssh_effective() {
  have sshd || return 20
  sshd -T 2>/dev/null | awk '$1 ~ /^(port|listenaddress|permitrootlogin|passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication|maxauthtries|logingracetime|allowusers|allowgroups|denyusers|denygroups)$/ {print}' | LC_ALL=C sort
}
inspect_cron_hashes() {
  local f
  # Hash contents without copying them into the baseline. Include both system
  # cron and per-user crontabs so persistent user-level scheduled changes are
  # visible without storing command text.
  for f in /etc/crontab /etc/cron.d/* /var/spool/cron/crontabs/* /var/spool/cron/*; do
    [[ -f "$f" && ! -L "$f" ]] || continue
    printf '%s\t%s\n' "$f" "$(sha256sum "$f" | awk '{print $1}')"
  done | LC_ALL=C sort -u
}
inspect_sysctl_security() {
  local k
  for k in net.ipv4.ip_forward net.ipv6.conf.all.forwarding net.ipv4.conf.all.accept_redirects net.ipv4.conf.default.accept_redirects net.ipv4.conf.all.send_redirects net.ipv4.conf.all.rp_filter kernel.kptr_restrict kernel.dmesg_restrict fs.protected_hardlinks fs.protected_symlinks; do
    printf '%s=%s\n' "$k" "$(sysctl -n "$k" 2>/dev/null || echo unavailable)"
  done
}

_snapshot_collect() {
  local out="$1" section="$2" filename="$3" fn="$4" tmp rc=0 status
  tmp="$out/.${filename}.new"
  if "$fn" > "$tmp" 2>/dev/null; then status=ok; else rc=$?; status="incomplete(rc=$rc)"; fi
  mv -f -- "$tmp" "$out/$filename" || return 40
  printf '%s\t%s\n' "$section" "$status" >> "$out/collection.tsv" || return 40
}

snapshot_capture() {
  local out="$1"
  mkdir -p "$out" || return 40; : > "$out/collection.tsv" || return 40
  _snapshot_collect "$out" listeners listeners.tsv inspect_listeners || return $?
  _snapshot_collect "$out" docker-ports docker-ports.tsv inspect_docker_ports || return $?
  _snapshot_collect "$out" users users.tsv inspect_users || return $?
  _snapshot_collect "$out" sudo sudo.tsv inspect_sudo_access || return $?
  _snapshot_collect "$out" authorized-keys authorized-keys.tsv inspect_authorized_keys || return $?
  _snapshot_collect "$out" services services.txt inspect_services || return $?
  _snapshot_collect "$out" docker docker.tsv inspect_docker_state || return $?
  _snapshot_collect "$out" firewall firewall.txt inspect_firewall_state || return $?
  _snapshot_collect "$out" ssh-effective ssh.txt inspect_ssh_effective || return $?
  _snapshot_collect "$out" cron cron.tsv inspect_cron_hashes || return $?
  _snapshot_collect "$out" sysctl sysctl.txt inspect_sysctl_security || return $?
  cat > "$out/manifest" <<EOF_MANIFEST
schema=2
created=$(date -Is)
hostname=$(hostname 2>/dev/null || echo unknown)
kernel=$(uname -r)
vpsg_version=$VPSG_VERSION
EOF_MANIFEST
  chmod 600 "$out"/* 2>/dev/null || true
}

snapshot_incomplete_count() {
  local dir="$1"
  [[ -r "$dir/collection.tsv" ]] || { echo 999; return 0; }
  awk -F'\t' '$2 != "ok" {n++} END {print n+0}' "$dir/collection.tsv"
}

snapshot_seal() {
  local dir="$1" tmp f
  [[ -d "$dir" && -f "$dir/manifest" && -f "$dir/collection.tsv" ]] || return 20
  tmp="$dir/.checksums.new"; : > "$tmp" || return 40
  while IFS= read -r f; do sha256sum "$dir/$f" | sed "s#  $dir/#  #" >> "$tmp" || { rm -f -- "$tmp"; return 40; }; done < <(find "$dir" -maxdepth 1 -type f ! -name checksums.sha256 ! -name .checksums.new -printf '%f\n' | LC_ALL=C sort)
  mv -f -- "$tmp" "$dir/checksums.sha256" || return 40; chmod 600 "$dir/checksums.sha256" 2>/dev/null || true
}

snapshot_verify() {
  local dir="$1" expected actual
  [[ -r "$dir/checksums.sha256" ]] || return 20
  (cd "$dir" && sha256sum -c checksums.sha256 >/dev/null 2>&1) || return 50
  expected="$(awk '{sub(/^\*/,"",$2); print $2}' "$dir/checksums.sha256" | LC_ALL=C sort)"
  actual="$(find "$dir" -maxdepth 1 -type f ! -name checksums.sha256 -printf '%f\n' | LC_ALL=C sort)"
  [[ "$expected" == "$actual" ]] || return 50
}
