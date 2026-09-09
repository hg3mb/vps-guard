#!/usr/bin/env bash

VPSG_TX_DIR="${VPSG_TX_DIR:-$VPSG_STATE_DIR/transactions}"
VPSG_TX_CURRENT="${VPSG_TX_CURRENT:-$VPSG_TX_DIR/current}"
VPSG_TX_DEFAULT_TIMEOUT="${VPSG_TX_DEFAULT_TIMEOUT:-180}"
VPSG_TX_SSH_CONF="${VPSG_TX_SSH_CONF:-$VPSG_SSH_CONFIG_DIR/00-vps-guard.conf}"
VPSG_TX_SSH_LEGACY_CONF="${VPSG_TX_SSH_LEGACY_CONF:-$VPSG_SSH_CONFIG_DIR/90-vps-guard.conf}"
VPSG_TX_SSH_MAIN_CONFIG="${VPSG_TX_SSH_MAIN_CONFIG:-$VPSG_SSH_MAIN_CONFIG}"
VPSG_TX_UFW_DIR="${VPSG_TX_UFW_DIR:-$VPSG_UFW_DIR}"
VPSG_TX_UFW_DEFAULT="${VPSG_TX_UFW_DEFAULT:-$VPSG_UFW_DEFAULT}"

_tx_valid_id() { [[ "${1:-}" =~ ^[0-9]{8}-[0-9]{6}-[0-9]{1,10}-[0-9a-f]{4}$ ]]; }

_tx_state_get() {
  local dir="$1" key="$2"
  awk -F= -v k="$key" '$1==k {print substr($0,index($0,"=")+1)}' "$dir/state" 2>/dev/null | tail -1
}

_tx_state_set() {
  local dir="$1" key="$2" value="$3" tmp previous="" had_previous=0
  [[ "$key" =~ ^[A-Za-z0-9_]+$ && "$value" != *$'\n'* ]] || return 64
  [[ -d "$dir" && ! -L "$dir" ]] || return 70
  [[ ! -e "$dir/state" || ( -f "$dir/state" && ! -L "$dir/state" ) ]] || return 70

  tmp="$(mktemp "$dir/.state.new.XXXXXX")" || return 40
  if [[ -f "$dir/state" ]]; then
    had_previous=1
    previous="$(mktemp "$dir/.state.prev.XXXXXX")" || { rm -f -- "$tmp"; return 40; }
    cp -p -- "$dir/state" "$previous" || { rm -f -- "$tmp" "$previous"; return 40; }
    grep -v "^${key}=" "$dir/state" > "$tmp" || true
  fi
  printf '%s=%s\n' "$key" "$value" >> "$tmp" || { rm -f -- "$tmp" "$previous"; return 40; }
  chmod 600 "$tmp" 2>/dev/null || { rm -f -- "$tmp" "$previous"; return 40; }
  mv -f -- "$tmp" "$dir/state" || { rm -f -- "$tmp" "$previous"; return 40; }

  if durable_sync_path "$dir/state"; then
    [[ -z "$previous" ]] || rm -f -- "$previous"
    return 0
  fi

  # A failed persistence barrier means the caller must not trust the new
  # transition. Restore the previous visible state so an armed/re-armed
  # rollback worker still sees the last durable phase (for example
  # commit_pending instead of a half-sealed committed state).
  if ((had_previous)); then
    mv -f -- "$previous" "$dir/state" 2>/dev/null || true
    durable_sync_path "$dir/state" >/dev/null 2>&1 || true
  else
    rm -f -- "$dir/state" 2>/dev/null || true
  fi
  rm -f -- "$tmp" "$previous" 2>/dev/null || true
  return 40
}

_tx_event() {
  local dir="$1" event="$2" detail="${3:-}"
  printf '%s\t%s\t%s\n' "$(date -Is)" "$event" "$detail" >> "$dir/events.log" 2>/dev/null || true
}

_tx_dir_for() { _tx_valid_id "$1" || return 64; printf '%s/%s\n' "$VPSG_TX_DIR" "$1"; }
_tx_current_id() {
  local id
  if [[ ! -e "$VPSG_TX_CURRENT" && ! -L "$VPSG_TX_CURRENT" ]]; then return 1; fi
  [[ -f "$VPSG_TX_CURRENT" && ! -L "$VPSG_TX_CURRENT" && -r "$VPSG_TX_CURRENT" ]] || return 70
  id="$(cat "$VPSG_TX_CURRENT" 2>/dev/null)" || return 70
  _tx_valid_id "$id" || return 70
  printf '%s\n' "$id"
}
_tx_write_current() { local id="$1"; _tx_valid_id "$id" || return 64; printf '%s\n' "$id" | atomic_write_file_durable "$VPSG_TX_CURRENT" 600; }
_tx_status_active() { case "$1" in preparing|applying|pending|commit_pending|apply_failed|rolling_back|rollback_failed) return 0;; *) return 1;; esac; }
_tx_status_terminal() { case "$1" in committed|rolled_back|prepare_failed|schedule_failed) return 0;; *) return 1;; esac; }

_tx_record_status() {
  local id="$1" dir status
  _tx_valid_id "$id" || return 70
  dir="$(_tx_dir_for "$id")" || return 70
  [[ -d "$dir" && ! -L "$dir" && -f "$dir/state" && ! -L "$dir/state" && -r "$dir/state" ]] || return 70
  status="$(_tx_state_get "$dir" status)"
  if _tx_status_active "$status" || _tx_status_terminal "$status"; then
    printf '%s\n' "$status"
    return 0
  fi
  return 70
}

# The `current` file is only a convenience pointer, never the source of truth.
# A power loss or manual deletion must not allow a second risky transaction to
# start while an older rollback timer is still armed. Discover active records
# from the transaction directory and fail closed on ambiguity/corruption.
_tx_active_id() {
  local current="" current_rc=0 current_status="" entry id status
  local -a active_ids=()

  if [[ -e "$VPSG_TX_DIR" || -L "$VPSG_TX_DIR" ]]; then
    [[ -d "$VPSG_TX_DIR" && ! -L "$VPSG_TX_DIR" ]] || return 70
  else
    return 1
  fi

  current="$(_tx_current_id 2>/dev/null)" || current_rc=$?
  case "$current_rc" in
    0)
      current_status="$(_tx_record_status "$current" 2>/dev/null)" || return 70
      if _tx_status_terminal "$current_status"; then
        rm -f -- "$VPSG_TX_CURRENT" 2>/dev/null || return 70
        current=""
      fi
      ;;
    1) current="" ;;
    *) return 70 ;;
  esac

  for entry in "$VPSG_TX_DIR"/*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    [[ -d "$entry" ]] || continue
    [[ ! -L "$entry" ]] || return 70
    id="${entry##*/}"
    _tx_valid_id "$id" || return 70
    status="$(_tx_record_status "$id" 2>/dev/null)" || return 70
    _tx_status_active "$status" && active_ids+=("$id")
  done

  case "${#active_ids[@]}" in
    0) return 1 ;;
    1)
      # If current names an active record it must agree with discovery.
      [[ -z "$current" || "$current" == "${active_ids[0]}" ]] || return 70
      printf '%s\n' "${active_ids[0]}"
      return 0
      ;;
    *) return 70 ;;
  esac
}

_tx_resolve_id() {
  local supplied="${1:-}" rc=0
  if [[ -n "$supplied" ]]; then _tx_valid_id "$supplied" || return 64; printf '%s\n' "$supplied"; return 0; fi
  _tx_active_id || rc=$?
  return "$rc"
}
_tx_pending_id() { _tx_active_id; }

_tx_lock_acquire() {
  local path="$1" outvar="$2" fd
  have flock || { error "Safe Change 需要 util-linux/flock 来防止并发事务"; return 20; }
  mkdir -p "$(dirname "$path")" || return 40
  exec {fd}>"$path" || return 40
  if ! flock -w 10 "$fd"; then eval "exec ${fd}>&-"; return 30; fi
  printf -v "$outvar" '%s' "$fd"
}
_tx_lock_release() { local fd="${1:-}"; [[ "$fd" =~ ^[0-9]+$ ]] || return 0; flock -u "$fd" 2>/dev/null || true; eval "exec ${fd}>&-"; }

_tx_new_id() {
  local id i
  for i in {1..20}; do
    id="$(date +%Y%m%d-%H%M%S)-$$-$(printf '%04x' "$((RANDOM % 65536))")"
    [[ ! -e "$VPSG_TX_DIR/$id" ]] && { printf '%s\n' "$id"; return 0; }
  done
  return 40
}

# Find the real SSH login process through /proc ancestry. Unlike SSH_CONNECTION,
# this survives sudo's normal env_reset policy. PID + kernel starttime prevents
# a recycled PID from being mistaken for the initiating login.
_tx_session_fingerprint() {
  if [[ -n "${VPSG_TEST_SESSION_FINGERPRINT:-}" ]]; then printf '%s\n' "$VPSG_TEST_SESSION_FINGERPRINT"; return 0; fi
  local pid="$$" ppid comm start i
  for i in {1..40}; do
    [[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/status" ]] || break
    comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
    if [[ "$comm" == sshd || "$comm" == sshd-session ]]; then
      start="$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true)"; [[ "$start" =~ ^[0-9]+$ ]] || start=unknown
      printf 'ssh:%s:%s\n' "$pid" "$start"; return 0
    fi
    ppid="$(awk '/^PPid:/ {print $2}' "/proc/$pid/status" 2>/dev/null)"
    [[ "$ppid" =~ ^[0-9]+$ && "$ppid" != 0 && "$ppid" != "$pid" ]] || break
    pid="$ppid"
  done
  echo console
}

_tx_snapshot_one() {
  local src="$1" dest="$2" presence="$3"
  if [[ -e "$src" ]]; then cp -a -- "$src" "$dest" || return 40; printf 'present\n' > "$presence" || return 40
  else printf 'absent\n' > "$presence" || return 40; fi
}

_tx_snapshot_ssh() {
  local dir="$1"
  mkdir -p "$dir/snapshot" || return 40
  _tx_snapshot_one "$VPSG_TX_SSH_CONF" "$dir/snapshot/ssh-00.conf" "$dir/snapshot/ssh-00.presence" || return $?
  _tx_snapshot_one "$VPSG_TX_SSH_LEGACY_CONF" "$dir/snapshot/ssh-90.conf" "$dir/snapshot/ssh-90.presence" || return $?
  [[ ! -e "$VPSG_TX_SSH_MAIN_CONFIG" ]] || cp -a -- "$VPSG_TX_SSH_MAIN_CONFIG" "$dir/snapshot/sshd_config.reference" || return 40
}

_tx_snapshot_firewall() {
  local dir="$1" active=0
  mkdir -p "$dir/snapshot" || return 40
  have ufw && ufw status 2>/dev/null | grep -q '^Status: active' && active=1
  printf '%s
' "$active" | atomic_write_file "$dir/snapshot/ufw.active" 600 || return 40
  if [[ -d "$VPSG_TX_UFW_DIR" && ! -L "$VPSG_TX_UFW_DIR" ]]; then
    tar -C "$VPSG_TX_UFW_DIR" -cpf "$dir/snapshot/ufw.tar" . || return 40
  elif [[ ! -e "$VPSG_TX_UFW_DIR" ]]; then
    : > "$dir/snapshot/ufw.absent" || return 40
  else
    error "UFW 配置路径异常（不是普通目录）: $VPSG_TX_UFW_DIR"
    return 40
  fi
  _tx_snapshot_one "$VPSG_TX_UFW_DEFAULT" "$dir/snapshot/default-ufw" "$dir/snapshot/default-ufw.presence" || return $?
}

_tx_precheck() {
  local module="$1" port
  have flock || { error "缺少 flock，无法安全串行化 Safe Change"; return 20; }
  have sync || { error "缺少 coreutils sync，无法持久化 Safe Change 关键状态"; return 20; }
  case "$module" in
    ssh)
      have sshd || { error "Safe Change: 未找到 sshd"; return 20; }
      have ss || { error "Safe Change: 缺少 ss/iproute2，无法确认 SSH 监听状态"; return 20; }
      sshd -t || { error "Safe Change: 当前 SSH 配置本身无法通过 sshd -t"; return 30; }
      port="$(ssh_primary_port 2>/dev/null || true)"; [[ -n "$port" ]] || { error "Safe Change: 无法确认当前 SSH 端口"; return 30; }
      ;;
    firewall)
      port="$(ssh_primary_port 2>/dev/null || true)"; [[ -n "$port" ]] || { error "Safe Change: 无法确认当前 SSH 端口，拒绝修改防火墙"; return 30; }
      ;;
    *) return 64 ;;
  esac
}

_tx_postverify() {
  local module="$1" port
  case "$module" in
    ssh) /bin/bash "$VPSG_ROOT/modules/builtin/ssh/module.sh" verify >/dev/null || return 1 ;;
    firewall) /bin/bash "$VPSG_ROOT/modules/builtin/firewall/module.sh" verify >/dev/null || return 1 ;;
    *) return 64 ;;
  esac
}

_tx_write_rollback_script() {
  local dir module id script current
  dir="$1"; module="$2"; id="$3"; current="$VPSG_TX_CURRENT"
  script="$dir/rollback.sh"
  cat > "$script" <<EOF_SCRIPT
#!/usr/bin/env bash
set -u
DIR=$(printf '%q' "$dir")
MODULE=$(printf '%q' "$module")
ID=$(printf '%q' "$id")
CURRENT=$(printf '%q' "$current")
SSH_CONF=$(printf '%q' "$VPSG_TX_SSH_CONF")
SSH_LEGACY_CONF=$(printf '%q' "$VPSG_TX_SSH_LEGACY_CONF")
UFW_DIR=$(printf '%q' "$VPSG_TX_UFW_DIR")
UFW_DEFAULT=$(printf '%q' "$VPSG_TX_UFW_DEFAULT")
SYSTEMD_DIR=$(printf '%q' "$VPSG_SYSTEMD_DIR")
UNIT=$(printf '%q' "$(_tx_unit_name "$id")")
LOCK="\$DIR/lock"
log() { printf '%s\\t%s\\n' "\$(date -Is)" "\$*" >> "\$DIR/rollback.log"; }
get_state() { awk -F= -v k="\$1" '\$1==k {print substr(\$0,index(\$0,"=")+1)}' "\$DIR/state" 2>/dev/null | tail -1; }
set_state() {
  local key="\$1" value="\$2" tmp previous="" had_previous=0
  tmp="\$(mktemp "\$DIR/.state.new.XXXXXX")" || return 40
  if [[ -f "\$DIR/state" && ! -L "\$DIR/state" ]]; then
    had_previous=1
    previous="\$(mktemp "\$DIR/.state.prev.XXXXXX")" || { rm -f -- "\$tmp"; return 40; }
    cp -p -- "\$DIR/state" "\$previous" || { rm -f -- "\$tmp" "\$previous"; return 40; }
    grep -v "^\${key}=" "\$DIR/state" > "\$tmp" 2>/dev/null || true
  elif [[ -e "\$DIR/state" || -L "\$DIR/state" ]]; then
    rm -f -- "\$tmp"; return 70
  fi
  printf '%s=%s\\n' "\$key" "\$value" >> "\$tmp" || { rm -f -- "\$tmp" "\$previous"; return 40; }
  chmod 600 "\$tmp" 2>/dev/null || { rm -f -- "\$tmp" "\$previous"; return 40; }
  mv -f -- "\$tmp" "\$DIR/state" || { rm -f -- "\$tmp" "\$previous"; return 40; }
  command -v sync >/dev/null 2>&1 || return 40
  if sync -f -- "\$DIR/state" >/dev/null 2>&1; then rm -f -- "\$previous" 2>/dev/null || true; return 0; fi
  if ((had_previous)); then mv -f -- "\$previous" "\$DIR/state" 2>/dev/null || true; sync -f -- "\$DIR/state" >/dev/null 2>&1 || true; else rm -f -- "\$DIR/state" 2>/dev/null || true; fi
  rm -f -- "\$tmp" "\$previous" 2>/dev/null || true
  return 40
}
restore_file() { local presence="\$1" snapshot="\$2" target="\$3"; mkdir -p "\$(dirname "\$target")" || return 1; if grep -qx absent "\$presence" 2>/dev/null; then rm -f -- "\$target"; else cp -a -- "\$snapshot" "\$target"; fi; }
exec 9>"\$LOCK" || exit 40
command -v flock >/dev/null 2>&1 && flock -w 30 9 || exit 30
status="\$(get_state status)"
case "\$status" in committed|rolled_back) log "rollback skipped status=\$status"; exit 0;; preparing|applying|pending|commit_pending|apply_failed|rollback_failed) ;; rolling_back) log "rollback already in progress"; exit 30;; *) log "rollback refused unknown status=\$status"; exit 30;; esac
set_state status rolling_back || exit 40
log "rollback started module=\$MODULE previous=\$status"
rc=0
case "\$MODULE" in
  ssh)
    restore_file "\$DIR/snapshot/ssh-00.presence" "\$DIR/snapshot/ssh-00.conf" "\$SSH_CONF" || rc=60
    restore_file "\$DIR/snapshot/ssh-90.presence" "\$DIR/snapshot/ssh-90.conf" "\$SSH_LEGACY_CONF" || rc=60
    if ((rc==0)) && command -v sshd >/dev/null 2>&1 && sshd -t; then
      if systemctl is-active --quiet ssh.socket 2>/dev/null; then
        systemctl daemon-reload >/dev/null 2>&1 && systemctl restart ssh.socket >/dev/null 2>&1 || rc=60
      else
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || rc=60
      fi
    else rc=60; fi
    ;;
  firewall)
    if [[ -f "\$DIR/snapshot/ufw.tar" ]]; then
      tar -tf "\$DIR/snapshot/ufw.tar" >/dev/null 2>&1 || rc=60
      if ((rc==0)); then
        parent="$(printf '%q' "$(dirname "$VPSG_TX_UFW_DIR")")"
        stage="\$parent/.vpsg-ufw-restore-\$ID"; old="\$parent/.vpsg-ufw-old-\$ID"
        rm -rf -- "\$stage" "\$old"; mkdir -p "\$stage" || rc=60
        ((rc!=0)) || tar -C "\$stage" -xpf "\$DIR/snapshot/ufw.tar" || rc=60
        if ((rc==0)); then
          [[ ! -e "\$UFW_DIR" ]] || mv -- "\$UFW_DIR" "\$old" || rc=60
          if ((rc==0)) && ! mv -- "\$stage" "\$UFW_DIR"; then [[ ! -e "\$old" ]] || mv -- "\$old" "\$UFW_DIR"; rc=60; fi
          rm -rf -- "\$old" "\$stage"
        fi
      fi
    elif [[ -f "\$DIR/snapshot/ufw.absent" ]]; then rm -rf -- "\$UFW_DIR"; fi
    restore_file "\$DIR/snapshot/default-ufw.presence" "\$DIR/snapshot/default-ufw" "\$UFW_DEFAULT" || rc=60
    if ((rc==0)) && command -v ufw >/dev/null 2>&1; then
      if grep -qx 1 "\$DIR/snapshot/ufw.active" 2>/dev/null; then ufw --force enable >/dev/null 2>&1 || rc=60; ((rc!=0)) || ufw reload >/dev/null 2>&1 || rc=60
      else ufw --force disable >/dev/null 2>&1 || rc=60; fi
    fi
    ;;
  *) rc=64 ;;
esac
if ((rc==0)); then
  if ! set_state status rolled_back; then
    log "rollback restored configuration but could not durably seal rolled_back state"
    set_state status rollback_failed >/dev/null 2>&1 || true
    exit 40
  fi
  set_state rolled_back_epoch "\$(date +%s)" || true
  log "rollback completed"
  if [[ -r "\$CURRENT" && "\$(cat "\$CURRENT" 2>/dev/null)" == "\$ID" ]]; then rm -f -- "\$CURRENT"; fi
  # Automatic rollback has no parent process to clean the one-shot timer.
  # Never remove a same-name unit unless both marker and transaction ID prove
  # that the file belongs to this transaction.
  service_file="\$SYSTEMD_DIR/\$UNIT.service"; timer_file="\$SYSTEMD_DIR/\$UNIT.timer"
  owned_file() { local f="\$1"; [[ ! -e "\$f" && ! -L "\$f" ]] && return 0; [[ -f "\$f" && ! -L "\$f" ]] || return 1; grep -Fqx '# Managed by VPS Guard' "\$f" 2>/dev/null && grep -Fqx "# Transaction: \$ID" "\$f" 2>/dev/null; }
  if owned_file "\$service_file" && owned_file "\$timer_file"; then
    if command -v systemctl >/dev/null 2>&1; then systemctl disable "\$UNIT.timer" >/dev/null 2>&1 || true; fi
    rm -f -- "\$timer_file" "\$service_file"
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1 || true
  else
    log "preserved unexpected same-name systemd unit during cleanup"
  fi
  exit 0
fi
set_state status rollback_failed || true
log "rollback FAILED rc=\$rc"
exit "\$rc"
EOF_SCRIPT
  chmod 700 "$script" || return 40
}

_tx_unit_name() { printf 'vpsg-rollback-%s\n' "$1"; }
_tx_unit_file_owned() {
  local file="${1:-}" id="${2:-}"
  [[ -f "$file" && ! -L "$file" ]] || return 1
  grep -Fqx '# Managed by VPS Guard' "$file" 2>/dev/null || return 1
  grep -Fqx "# Transaction: $id" "$file" 2>/dev/null
}
_tx_unit_paths_trusted() {
  local id="$1" service_file="$2" timer_file="$3" f
  for f in "$service_file" "$timer_file"; do
    [[ ! -e "$f" && ! -L "$f" ]] && continue
    _tx_unit_file_owned "$f" "$id" || { error "拒绝覆盖/删除非本事务拥有的 systemd unit: $f"; return 70; }
  done
}
_tx_schedule() {
  local dir="$1" id="$2" unit deadline service_file timer_file rollback_arg
  unit="$(_tx_unit_name "$id")"; deadline="$(_tx_state_get "$dir" deadline_epoch)"
  if [[ "${VPSG_TX_SCHEDULER:-systemd}" == manual ]]; then : > "$dir/manual-scheduler"; return 0; fi
  have systemctl || { error "缺少 systemctl，无法提供断线自动回滚保护"; return 30; }
  systemctl show-environment >/dev/null 2>&1 || { error "systemd 未运行，无法创建自动回滚计时器"; return 30; }
  [[ "$deadline" =~ ^[0-9]+$ ]] || return 30
  mkdir -p "$VPSG_SYSTEMD_DIR" || return 40
  service_file="$VPSG_SYSTEMD_DIR/${unit}.service"; timer_file="$VPSG_SYSTEMD_DIR/${unit}.timer"
  _tx_unit_paths_trusted "$id" "$service_file" "$timer_file" || return $?
  rollback_arg="$(systemd_quote_arg "$dir/rollback.sh")" || return 64
  atomic_write_file "$service_file" 644 <<EOF_SERVICE || return 40
# Managed by VPS Guard
# Transaction: $id
[Unit]
Description=VPS Guard automatic rollback for transaction $id
[Service]
Type=oneshot
ExecStart=/bin/bash $rollback_arg
PrivateTmp=true
UMask=0077
EOF_SERVICE
  atomic_write_file "$timer_file" 644 <<EOF_TIMER || { rm -f -- "$service_file"; return 40; }
# Managed by VPS Guard
# Transaction: $id
[Unit]
Description=VPS Guard rollback deadline for transaction $id
[Timer]
OnCalendar=@$deadline
AccuracySec=1s
Persistent=true
Unit=${unit}.service
[Install]
WantedBy=timers.target
EOF_TIMER
  systemctl daemon-reload || return 40
  systemctl enable --now "${unit}.timer" >/dev/null 2>&1 || return 40
}

_tx_cancel_timer() {
  local id="$1" unit service_file timer_file
  _tx_valid_id "$id" || return 64; unit="$(_tx_unit_name "$id")"
  [[ "${VPSG_TX_SCHEDULER:-systemd}" == manual ]] && return 0
  service_file="$VPSG_SYSTEMD_DIR/${unit}.service"; timer_file="$VPSG_SYSTEMD_DIR/${unit}.timer"
  _tx_unit_paths_trusted "$id" "$service_file" "$timer_file" || return $?
  systemctl disable --now "$unit.timer" >/dev/null 2>&1 || true
  systemctl stop "$unit.service" >/dev/null 2>&1 || true
  rm -f -- "$service_file" "$timer_file"
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed "$unit.service" >/dev/null 2>&1 || true
}

# Abort a transaction that has not yet armed a rollback timer or modified the
# target service. Such a preparation failure must not strand the server in an
# artificial "active transaction" state forever. Preserve an auditable terminal
# record when possible; if even state persistence is broken, remove the unarmed
# record because there is nothing to roll back.
_tx_abort_preapply() {
  local dir="$1" id="$2" reason="${3:-prepare_failed}"
  _tx_valid_id "$id" || return 64
  _tx_event "$dir" PREPARE_FAIL "$reason"
  if _tx_state_set "$dir" status prepare_failed; then
    _tx_state_set "$dir" prepare_failed_reason "$reason" >/dev/null 2>&1 || true
  else
    [[ "$(_tx_current_id 2>/dev/null || true)" != "$id" ]] || rm -f -- "$VPSG_TX_CURRENT"
    safe_rm_rf_within "$dir" "$VPSG_TX_DIR" >/dev/null 2>&1 || true
    return 40
  fi
  [[ "$(_tx_current_id 2>/dev/null || true)" != "$id" ]] || rm -f -- "$VPSG_TX_CURRENT"
  return 0
}

# Commit is the one place where timer cancellation is part of the state
# transition contract rather than best-effort cleanup. Verify that the timer is
# actually gone before making `committed` authoritative.
_tx_cancel_timer_strict() {
  local id="$1" unit service_file timer_file
  _tx_valid_id "$id" || return 64
  [[ "${VPSG_TX_SCHEDULER:-systemd}" == manual ]] && return 0
  have systemctl || return 40
  unit="$(_tx_unit_name "$id")"
  service_file="$VPSG_SYSTEMD_DIR/${unit}.service"; timer_file="$VPSG_SYSTEMD_DIR/${unit}.timer"
  _tx_unit_paths_trusted "$id" "$service_file" "$timer_file" || return $?
  systemctl disable --now "$unit.timer" >/dev/null 2>&1 || true
  systemctl stop "$unit.service" >/dev/null 2>&1 || true
  rm -f -- "$service_file" "$timer_file" || return 40
  systemctl daemon-reload >/dev/null 2>&1 || return 40
  systemctl is-active --quiet "$unit.timer" >/dev/null 2>&1 && return 40
  systemctl is-enabled --quiet "$unit.timer" >/dev/null 2>&1 && return 40
  [[ ! -e "$service_file" && ! -L "$service_file" && ! -e "$timer_file" && ! -L "$timer_file" ]] || return 40
  return 0
}

_tx_begin_inner() {
  local module="$1" timeout="$2" id dir now deadline port session
  case "$module" in ssh|firewall) ;; *) error "Safe Change 当前仅支持 ssh/firewall"; return 64;; esac
  [[ "$timeout" =~ ^[0-9]+$ ]] && ((timeout >= 30 && timeout <= 1800)) || { error "自动回滚时间必须为 30-1800 秒"; return 64; }
  _tx_precheck "$module" || return $?
  local active_rc=0
  if _tx_active_id >/dev/null 2>&1; then
    error "已有未完成 Safe Change，请先 commit 或 rollback"; return 30
  else
    active_rc=$?
    if ((active_rc != 1)); then error "Safe Change current 状态异常，拒绝覆盖安全事务指针。请检查 $VPSG_TX_CURRENT"; return 70; fi
  fi
  ensure_runtime_dirs || return 40; mkdir -p "$VPSG_TX_DIR" || return 40; chmod 700 "$VPSG_TX_DIR" 2>/dev/null || true
  id="$(_tx_new_id)" || return 40; dir="$(_tx_dir_for "$id")"; mkdir -p "$dir" || return 40; chmod 700 "$dir" || return 40
  now="$(date +%s)"; deadline=$((now+timeout)); port="$(ssh_primary_port 2>/dev/null || true)"; session="$(_tx_session_fingerprint)"
  cat <<EOF_STATE | atomic_write_file_durable "$dir/state" 600 || { safe_rm_rf_within "$dir" "$VPSG_TX_DIR" >/dev/null 2>&1 || true; return 40; }
id=$id
module=$module
status=preparing
created_epoch=$now
deadline_epoch=$deadline
timeout=$timeout
ssh_port=${port:-unknown}
initiator_session=$session
EOF_STATE
  case "$module" in
    ssh) _tx_snapshot_ssh "$dir" || { _tx_abort_preapply "$dir" "$id" snapshot_failed >/dev/null 2>&1 || true; return 40; };;
    firewall) _tx_snapshot_firewall "$dir" || { _tx_abort_preapply "$dir" "$id" snapshot_failed >/dev/null 2>&1 || true; return 40; };;
  esac
  _tx_write_rollback_script "$dir" "$module" "$id" || { _tx_abort_preapply "$dir" "$id" rollback_builder_failed >/dev/null 2>&1 || true; return 40; }
  _tx_write_current "$id" || { _tx_abort_preapply "$dir" "$id" current_pointer_failed >/dev/null 2>&1 || true; return 40; }
  _tx_state_set "$dir" status applying || { _tx_abort_preapply "$dir" "$id" state_transition_failed >/dev/null 2>&1 || true; return 40; }
  _tx_event "$dir" BEGIN "timeout=${timeout}s ssh_port=${port:-unknown} session=$session"
  if ! _tx_schedule "$dir" "$id"; then _tx_cancel_timer "$id" >/dev/null 2>&1 || true; _tx_state_set "$dir" status schedule_failed || true; [[ "$(_tx_current_id 2>/dev/null || true)" != "$id" ]] || rm -f -- "$VPSG_TX_CURRENT"; return 30; fi
  log_event INFO "safe transaction started id=$id module=$module timeout=$timeout"
  printf '%s\n' "$id"
}

tx_begin() {
  require_root || return 1
  local lockfd rc
  ensure_runtime_dirs || return 40; mkdir -p "$VPSG_TX_DIR" || return 40
  _tx_lock_acquire "$VPSG_TX_DIR/global.lock" lockfd || { error "另一个 Safe Change 正在创建/确认，请稍后重试"; return 30; }
  _tx_begin_inner "$@"; rc=$?; _tx_lock_release "$lockfd"; return "$rc"
}

tx_commit() {
  require_root || return 1
  local id="" console_confirm=0 a dir status module initial_session current_session lockfd rc=0
  while (($#)); do a="$1"; shift; case "$a" in --console-confirm) console_confirm=1;; *) [[ -z "$id" ]] && id="$a" || { error "未知参数: $a"; return 64; };; esac; done
  local resolve_rc=0
  id="$(_tx_resolve_id "$id" 2>/dev/null)" || resolve_rc=$?
  if ((resolve_rc==1)); then error "没有待处理的 Safe Change 事务"; return 20; fi
  if ((resolve_rc!=0)); then error "Safe Change current 指针异常，拒绝继续。请检查 $VPSG_TX_CURRENT"; return 70; fi
  dir="$(_tx_dir_for "$id")"; [[ -d "$dir" ]] || { error "事务不存在: $id"; return 20; }
  _tx_lock_acquire "$dir/lock" lockfd || { error "事务正在由另一个进程处理"; return 30; }
  status="$(_tx_state_get "$dir" status)"; module="$(_tx_state_get "$dir" module)"
  if [[ "$status" != pending && "$status" != commit_pending ]]; then
    error "事务状态为 $status，不能 commit"; rc=30
  elif ! _tx_postverify "$module"; then
    error "最终验证失败，拒绝 commit。建议 sudo vpsg safe rollback $id"; _tx_event "$dir" VERIFY_FAIL "commit refused"; rc=50
  else
    initial_session="$(_tx_state_get "$dir" initiator_session)"; current_session="$(_tx_session_fingerprint)"
    if [[ "$initial_session" == ssh:* ]]; then
      if [[ "$current_session" == "$initial_session" ]]; then
        error "仍处于发起修改的原 SSH 登录会话。请新开终端重新 SSH 登录后再 commit。"; _tx_event "$dir" SESSION_FAIL same-session; rc=30
      elif [[ "$current_session" == console && "$console_confirm" != 1 ]]; then
        error "当前看起来是控制台/非 SSH 会话。若正在 Provider Console 确认网络正常，请显式使用 --console-confirm。"; rc=30
      fi
    fi
  fi

  if ((rc==0)); then
    _tx_event "$dir" VERIFY_OK "commit verification passed session=$current_session"
    # A two-phase commit keeps rollback valid until timer cancellation has been
    # verified. The rollback script deliberately treats commit_pending as an
    # active state, so a crash in this window still fails toward recovery.
    if [[ "$status" == pending ]]; then
      _tx_state_set "$dir" status commit_pending || rc=40
      ((rc==0)) && _tx_event "$dir" COMMIT_PREPARE "timer cancellation pending"
    fi
  fi

  if ((rc==0)); then
    if ! _tx_cancel_timer_strict "$id"; then
      _tx_event "$dir" TIMER_CANCEL_FAIL "commit kept non-terminal"
      # Restore the safety net if possible. If re-arming succeeds, return to
      # pending so the administrator can retry; otherwise keep commit_pending
      # active/fail-closed and leave the transaction visible for recovery.
      if _tx_schedule "$dir" "$id" >/dev/null 2>&1; then
        _tx_state_set "$dir" status pending >/dev/null 2>&1 || true
      fi
      error "无法确认自动回滚计时器已取消；事务未 commit。请检查 Safe Change 状态后重试。"
      rc=40
    fi
  fi

  if ((rc==0)); then
    _tx_state_set "$dir" status committed || rc=40
    if ((rc==0)); then
      _tx_state_set "$dir" committed_epoch "$(date +%s)" || warn "事务已 commit，但 committed_epoch 元数据写入失败"
      _tx_event "$dir" COMMIT "confirmed by administrator"
      [[ "$(_tx_current_id 2>/dev/null || true)" == "$id" ]] && rm -f -- "$VPSG_TX_CURRENT"
    else
      _tx_event "$dir" COMMIT_SEAL_FAIL "committed state persistence failed"
      # The timer was already removed by the strict cancellation phase. A
      # failed durable commit must restore the safety net; _tx_state_set keeps
      # the previous commit_pending state visible on persistence failure, so
      # the rollback worker will still treat the transaction as active.
      if _tx_schedule "$dir" "$id" >/dev/null 2>&1; then
        warn "commit 状态无法可靠封存；已重新启用自动回滚保护。请检查磁盘/文件系统后重试 commit。"
      else
        error "commit 状态无法可靠封存，而且自动回滚计时器无法重新启用。事务保持非终态并阻止新的危险修改；请立即检查系统状态。"
      fi
    fi
  fi
  _tx_lock_release "$lockfd"
  if ((rc==0)); then log_event INFO "safe transaction committed id=$id"; ok "已确认事务 $id；自动回滚已取消。"; fi
  return "$rc"
}

tx_manual_rollback() {
  require_root || return 1
  local id="${1:-}" dir status rc=0
  local resolve_rc=0
  id="$(_tx_resolve_id "$id" 2>/dev/null)" || resolve_rc=$?
  if ((resolve_rc==1)); then error "没有 Safe Change 事务"; return 20; fi
  if ((resolve_rc!=0)); then error "Safe Change current 指针异常，拒绝继续。请检查 $VPSG_TX_CURRENT"; return 70; fi
  dir="$(_tx_dir_for "$id")"; [[ -f "$dir/rollback.sh" ]] || { error "事务回滚脚本不存在"; return 20; }
  status="$(_tx_state_get "$dir" status)"; _tx_status_active "$status" || { error "事务状态为 $status，不能回滚"; return 30; }
  _tx_event "$dir" ROLLBACK_REQUEST manual
  /bin/bash "$dir/rollback.sh" || rc=$?
  if ((rc==0)); then _tx_cancel_timer "$id" || true; [[ "$(_tx_current_id 2>/dev/null || true)" == "$id" ]] && rm -f -- "$VPSG_TX_CURRENT"; fi
  log_event INFO "safe transaction rollback id=$id rc=$rc"; return "$rc"
}

tx_extend() {
  require_root || return 1
  local id="${1:-}" seconds="${2:-}" dir status old now new lockfd rc=0
  local resolve_rc=0
  id="$(_tx_resolve_id "$id" 2>/dev/null)" || resolve_rc=$?
  ((resolve_rc==0)) || { ((resolve_rc==1)) && return 20; error "Safe Change current 指针异常，拒绝继续。"; return 70; }
  [[ "$seconds" =~ ^[0-9]+$ ]] && ((seconds>=30 && seconds<=1800)) || { error "延长时间必须为 30-1800 秒"; return 64; }
  dir="$(_tx_dir_for "$id")"; [[ -d "$dir" ]] || return 20
  _tx_lock_acquire "$dir/lock" lockfd || return 30
  status="$(_tx_state_get "$dir" status)"; [[ "$status" == pending ]] || { _tx_lock_release "$lockfd"; error "只有 pending 事务可以延长"; return 30; }
  old="$(_tx_state_get "$dir" deadline_epoch)"; now="$(date +%s)"; new=$((now+seconds))
  _tx_state_set "$dir" deadline_epoch "$new" || rc=40
  if ((rc==0)); then _tx_cancel_timer "$id" || true; if ! _tx_schedule "$dir" "$id"; then _tx_state_set "$dir" deadline_epoch "$old" || true; _tx_schedule "$dir" "$id" >/dev/null 2>&1 || true; rc=40; fi; fi
  ((rc!=0)) || _tx_event "$dir" EXTEND "new_deadline=$new seconds=$seconds"
  _tx_lock_release "$lockfd"
  ((rc==0)) && ok "事务 $id 的自动回滚时间已延长 $seconds 秒"
  return "$rc"
}

tx_status() {
  local id="${1:-}" dir status module deadline now remain
  local resolve_rc=0
  id="$(_tx_resolve_id "$id" 2>/dev/null)" || resolve_rc=$?
  if ((resolve_rc==1)); then echo "没有待确认的 Safe Change。"; return 0; fi
  if ((resolve_rc!=0)); then error "Safe Change current 指针损坏或不可信: $VPSG_TX_CURRENT"; return 70; fi
  dir="$(_tx_dir_for "$id")"; [[ -d "$dir" && ! -L "$dir" ]] || { error "事务记录不存在或类型异常: $id"; return 70; }
  status="$(_tx_state_get "$dir" status)"; module="$(_tx_state_get "$dir" module)"; deadline="$(_tx_state_get "$dir" deadline_epoch)"; now="$(date +%s)"; remain=0
  [[ "$deadline" =~ ^[0-9]+$ ]] && ((deadline>now)) && remain=$((deadline-now))
  printf '事务: %s\n模块: %s\n状态: %s\nSSH 端口: %s\n发起会话: %s\n' "$id" "$module" "$status" "$(_tx_state_get "$dir" ssh_port)" "$(_tx_state_get "$dir" initiator_session)"
  if [[ "$status" == pending ]]; then
    printf '自动回滚剩余: %s 秒\n确认保留: sudo vpsg commit %s\n延长时间: sudo vpsg safe extend %s 300\n立即回滚: sudo vpsg safe rollback %s\n' "$remain" "$id" "$id" "$id"
  elif [[ "$status" == commit_pending ]]; then
    printf 'Commit 尚未完整封存。不要开始新的危险修改。\n重新确认: sudo vpsg commit %s\n放弃修改并恢复: sudo vpsg safe rollback %s\n' "$id" "$id"
  fi
}

tx_history() {
  local limit="${1:-20}" d id status module created
  [[ "$limit" =~ ^[0-9]+$ ]] || limit=20
  [[ -d "$VPSG_TX_DIR" ]] || { echo "暂无 Safe Change 历史。"; return 0; }
  printf '%-32s %-10s %-15s %s\n' TRANSACTION MODULE STATUS CREATED
  find "$VPSG_TX_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | LC_ALL=C sort -r | head -n "$limit" | while read -r id; do
    _tx_valid_id "$id" || continue; d="$VPSG_TX_DIR/$id"; status="$(_tx_state_get "$d" status)"; module="$(_tx_state_get "$d" module)"; created="$(_tx_state_get "$d" created_epoch)"
    [[ "$created" =~ ^[0-9]+$ ]] && created="$(date -d "@$created" '+%F %T' 2>/dev/null || echo "$created")"
    printf '%-32s %-10s %-15s %s\n' "$id" "$module" "$status" "$created"
  done
}

tx_show() {
  local id="${1:-}" dir
  _tx_valid_id "$id" || { error "用法: vpsg safe show <transaction-id>"; return 64; }
  dir="$(_tx_dir_for "$id")"; [[ -d "$dir" ]] || { error "事务不存在: $id"; return 20; }
  cat "$dir/state"; [[ ! -r "$dir/events.log" ]] || { echo; echo '事件:'; cat "$dir/events.log"; }; [[ ! -r "$dir/rollback.log" ]] || { echo; echo '回滚日志:'; cat "$dir/rollback.log"; }
}

_tx_prepare_module() {
  local module="$1"
  case "$module" in
    firewall) route_module firewall prepare ;;
    ssh) route_module ssh prepare ;;
    *) return 64 ;;
  esac
}

tx_safe_apply() {
  require_root || return 1
  local module="${1:-}" action="${2:-}"; shift 2 2>/dev/null || true
  [[ "$action" == apply ]] || { error "用法: sudo vpsg safe <ssh|firewall> apply [--timeout 180] [--yes]"; return 64; }
  local timeout="$VPSG_TX_DEFAULT_TIMEOUT" args=() a id dir rc=0
  while (($#)); do a="$1"; case "$a" in --timeout) [[ $# -ge 2 ]] || return 64; timeout="$2"; shift 2;; *) args+=("$1"); shift;; esac; done
  # Install non-risky dependencies before the rollback countdown starts and
  # before the snapshot is taken. This keeps snapshots semantically complete.
  _tx_prepare_module "$module" || return $?
  id="$(tx_begin "$module" "$timeout")" || return $?; dir="$(_tx_dir_for "$id")"
  info "Safe Change 已启动：${timeout} 秒后若未 commit 将自动回滚。"; info "事务 ID: $id"
  route_module "$module" apply "${args[@]}"; rc=$?
  if ((rc!=0)); then
    _tx_state_set "$dir" status apply_failed || true; _tx_event "$dir" APPLY_FAIL "rc=$rc"
    error "应用失败，立即恢复事务快照。"
    if ! tx_manual_rollback "$id" >/dev/null 2>&1; then
      error "安全回滚也失败了。事务已保留为 rollback_failed；请保持当前会话并使用 Provider Console/救援模式检查。"
      return 60
    fi
    return "$rc"
  fi
  if ! _tx_postverify "$module"; then
    _tx_state_set "$dir" status apply_failed || true; _tx_event "$dir" VERIFY_FAIL post-apply
    error "修改后自检失败，立即自动回滚。"
    if ! tx_manual_rollback "$id" >/dev/null 2>&1; then
      error "安全回滚失败。请保持当前会话并使用 Provider Console/救援模式检查。"
      return 60
    fi
    return 50
  fi
  if ! _tx_state_set "$dir" status pending; then
    error "无法可靠保存 pending 状态，立即回滚"
    _tx_state_set "$dir" status apply_failed || true
    if ! tx_manual_rollback "$id" >/dev/null 2>&1; then error "安全回滚失败，请立即使用 Provider Console 检查。"; return 60; fi
    return 40
  fi
  _tx_event "$dir" APPLY_OK "post-apply verification passed"
  cat <<EOF_DONE

修改已应用，但尚未永久确认。
请保持当前 SSH 会话，并在新的终端重新连接服务器。
验证正常后执行：
  sudo vpsg commit $id
如果 ${timeout} 秒内没有确认，系统会自动恢复修改前状态。
EOF_DONE
}
