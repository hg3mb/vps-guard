#!/usr/bin/env bash

VPSG_TX_DIR="${VPSG_TX_DIR:-$VPSG_STATE_DIR/transactions}"
VPSG_TX_CURRENT="${VPSG_TX_CURRENT:-$VPSG_TX_DIR/current}"
VPSG_TX_DEFAULT_TIMEOUT="${VPSG_TX_DEFAULT_TIMEOUT:-180}"

_tx_state_get() {
  local dir="$1" key="$2"
  awk -F= -v k="$key" '$1==k {print substr($0,index($0,"=")+1)}' "$dir/state" 2>/dev/null | tail -1
}

_tx_state_set() {
  local dir="$1" key="$2" value="$3" tmp
  tmp="$(mktemp)"
  if [[ -f "$dir/state" ]]; then grep -v "^${key}=" "$dir/state" > "$tmp" || true; fi
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv "$tmp" "$dir/state"
  chmod 600 "$dir/state" 2>/dev/null || true
}

_tx_event() {
  local dir="$1" event="$2" detail="${3:-}"
  printf '%s\t%s\t%s\n' "$(date -Is)" "$event" "$detail" >> "$dir/events.log"
}

_tx_current_id() { [[ -r "$VPSG_TX_CURRENT" ]] || return 1; cat "$VPSG_TX_CURRENT"; }
_tx_dir_for() { printf '%s/%s\n' "$VPSG_TX_DIR" "$1"; }
_tx_pending_id() {
  local id dir status
  id="$(_tx_current_id 2>/dev/null || true)"; [[ -n "$id" ]] || return 1
  dir="$(_tx_dir_for "$id")"; [[ -d "$dir" ]] || return 1
  status="$(_tx_state_get "$dir" status)"; [[ "$status" == "pending" ]] || return 1
  printf '%s\n' "$id"
}
_tx_new_id() { printf '%s-%04x\n' "$(date +%Y%m%d-%H%M%S)" "$((RANDOM % 65536))"; }

_tx_snapshot_ssh() {
  local dir="$1" conf="/etc/ssh/sshd_config.d/90-vps-guard.conf"
  mkdir -p "$dir/snapshot"
  if [[ -e "$conf" ]]; then cp -a "$conf" "$dir/snapshot/ssh.conf"; printf 'present\n' > "$dir/snapshot/ssh.presence"; else printf 'absent\n' > "$dir/snapshot/ssh.presence"; fi
  [[ ! -e /etc/ssh/sshd_config ]] || cp -a /etc/ssh/sshd_config "$dir/snapshot/sshd_config.reference"
}

_tx_snapshot_firewall() {
  local dir="$1" active=0
  mkdir -p "$dir/snapshot"
  have ufw && ufw status 2>/dev/null | grep -q '^Status: active' && active=1
  printf '%s\n' "$active" > "$dir/snapshot/ufw.active"
  if [[ -d /etc/ufw ]]; then tar -C /etc -cpf "$dir/snapshot/ufw.tar" ufw; else : > "$dir/snapshot/ufw.absent"; fi
  if [[ -e /etc/default/ufw ]]; then cp -a /etc/default/ufw "$dir/snapshot/default-ufw"; else : > "$dir/snapshot/default-ufw.absent"; fi
}

_tx_precheck() {
  local module="$1" port
  case "$module" in
    ssh)
      have sshd || { error "Safe Change: 未找到 sshd"; return 20; }
      sshd -t || { error "Safe Change: 当前 SSH 配置本身无法通过 sshd -t"; return 30; }
      port="$(ssh_primary_port 2>/dev/null || true)"; [[ -n "$port" ]] || { error "Safe Change: 无法确认当前 SSH 端口"; return 30; }
      ;;
    firewall)
      port="$(ssh_primary_port 2>/dev/null || true)"; [[ -n "$port" ]] || { error "Safe Change: 无法确认当前 SSH 端口，拒绝修改防火墙"; return 30; }
      ;;
    *) return 64 ;;
  esac
  return 0
}

_tx_postverify() {
  local module="$1" port
  case "$module" in
    ssh)
      sshd -t || return 1
      port="$(ssh_primary_port 2>/dev/null || true)"
      [[ -n "$port" ]] && ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$port$" || return 1
      ;;
    firewall)
      /bin/bash "$VPSG_ROOT/modules/builtin/firewall/module.sh" verify >/dev/null || return 1
      ;;
  esac
}

_tx_write_rollback_script() {
  local dir="$1" module="$2" script="$dir/rollback.sh"
  cat > "$script" <<EOF_SCRIPT
#!/usr/bin/env bash
set -u
DIR=$(printf '%q' "$dir")
MODULE=$(printf '%q' "$module")
log() { printf '%s\t%s\n' "\$(date -Is)" "\$*" >> "\$DIR/rollback.log"; }
set_state() { local key="\$1" value="\$2" tmp; tmp="\$(mktemp)"; grep -v "^\${key}=" "\$DIR/state" > "\$tmp" 2>/dev/null || true; printf '%s=%s\\n' "\$key" "\$value" >> "\$tmp"; mv "\$tmp" "\$DIR/state"; }
log "automatic rollback started module=\$MODULE"
case "\$MODULE" in
  ssh)
    mkdir -p /etc/ssh/sshd_config.d
    if grep -qx absent "\$DIR/snapshot/ssh.presence" 2>/dev/null; then rm -f /etc/ssh/sshd_config.d/90-vps-guard.conf; else cp -a "\$DIR/snapshot/ssh.conf" /etc/ssh/sshd_config.d/90-vps-guard.conf; fi
    if command -v sshd >/dev/null 2>&1 && sshd -t; then systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true; set_state status rolled_back; log "ssh rollback completed"; exit 0; fi
    set_state status rollback_failed; log "ssh rollback validation failed"; exit 60 ;;
  firewall)
    if [[ -f "\$DIR/snapshot/ufw.tar" ]]; then rm -rf /etc/ufw; tar -C /etc -xpf "\$DIR/snapshot/ufw.tar"; fi
    if [[ -f "\$DIR/snapshot/default-ufw" ]]; then cp -a "\$DIR/snapshot/default-ufw" /etc/default/ufw; elif [[ -f "\$DIR/snapshot/default-ufw.absent" ]]; then rm -f /etc/default/ufw; fi
    if command -v ufw >/dev/null 2>&1; then if grep -qx 1 "\$DIR/snapshot/ufw.active" 2>/dev/null; then ufw --force enable >/dev/null 2>&1 || true; ufw reload >/dev/null 2>&1 || true; else ufw --force disable >/dev/null 2>&1 || true; fi; fi
    set_state status rolled_back; log "firewall rollback completed"; exit 0 ;;
  *) set_state status rollback_failed; log "unsupported module"; exit 64 ;;
esac
EOF_SCRIPT
  chmod 700 "$script"
}

_tx_schedule() {
  local dir="$1" id="$2" timeout="$3" unit="vpsg-rollback-${id//[^A-Za-z0-9_.-]/-}" deadline service_file timer_file
  deadline="$(_tx_state_get "$dir" deadline_epoch)"; _tx_state_set "$dir" unit "$unit"
  if [[ "${VPSG_TX_SCHEDULER:-systemd}" == "manual" ]]; then : > "$dir/manual-scheduler"; return 0; fi
  have systemctl || { error "缺少 systemctl，无法提供断线自动回滚保护"; return 30; }
  systemctl show-environment >/dev/null 2>&1 || { error "systemd 未运行，无法创建自动回滚计时器"; return 30; }
  [[ "$deadline" =~ ^[0-9]+$ ]] || return 30
  service_file="/etc/systemd/system/${unit}.service"; timer_file="/etc/systemd/system/${unit}.timer"
  cat > "$service_file" <<EOF_SERVICE
[Unit]
Description=VPS Guard automatic rollback for transaction $id
[Service]
Type=oneshot
ExecStart=/bin/bash $dir/rollback.sh
EOF_SERVICE
  cat > "$timer_file" <<EOF_TIMER
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
  chmod 644 "$service_file" "$timer_file"; systemctl daemon-reload || return 40; systemctl enable --now "${unit}.timer" >/dev/null 2>&1 || return 40
}

_tx_cancel_timer() {
  local dir="$1" unit service_file timer_file
  unit="$(_tx_state_get "$dir" unit)"; [[ -n "$unit" ]] || return 0
  if [[ "${VPSG_TX_SCHEDULER:-systemd}" != "manual" ]]; then
    systemctl disable --now "$unit.timer" >/dev/null 2>&1 || true; systemctl stop "$unit.service" >/dev/null 2>&1 || true
    service_file="/etc/systemd/system/${unit}.service"; timer_file="/etc/systemd/system/${unit}.timer"; rm -f "$service_file" "$timer_file"
    systemctl daemon-reload >/dev/null 2>&1 || true; systemctl reset-failed "$unit.service" >/dev/null 2>&1 || true
  fi
}

tx_begin() {
  require_root || return 1
  local module="$1" timeout="$2" id dir now deadline port
  case "$module" in ssh|firewall) ;; *) error "Safe Change 当前仅支持 ssh/firewall"; return 64;; esac
  [[ "$timeout" =~ ^[0-9]+$ ]] && (( timeout >= 30 && timeout <= 1800 )) || { error "自动回滚时间必须为 30-1800 秒"; return 64; }
  _tx_precheck "$module" || return $?
  if _tx_pending_id >/dev/null 2>&1; then error "已有未确认 Safe Change，请先 commit 或 rollback"; return 30; fi
  ensure_runtime_dirs; mkdir -p "$VPSG_TX_DIR"; chmod 700 "$VPSG_TX_DIR" 2>/dev/null || true
  id="$(_tx_new_id)"; dir="$(_tx_dir_for "$id")"; mkdir -p "$dir"; chmod 700 "$dir"
  now="$(date +%s)"; deadline=$((now + timeout)); port="$(ssh_primary_port 2>/dev/null || true)"
  cat > "$dir/state" <<EOF_STATE
id=$id
module=$module
status=preparing
created_epoch=$now
deadline_epoch=$deadline
timeout=$timeout
ssh_port=${port:-unknown}
remote=${SSH_CONNECTION:-unknown}
EOF_STATE
  case "$module" in ssh) _tx_snapshot_ssh "$dir" || return 40;; firewall) _tx_snapshot_firewall "$dir" || return 40;; esac
  _tx_write_rollback_script "$dir" "$module"; _tx_state_set "$dir" status pending; _tx_event "$dir" BEGIN "timeout=${timeout}s ssh_port=${port:-unknown}"
  printf '%s\n' "$id" > "$VPSG_TX_CURRENT"; chmod 600 "$VPSG_TX_CURRENT"
  if ! _tx_schedule "$dir" "$id" "$timeout"; then _tx_state_set "$dir" status schedule_failed; _tx_cancel_timer "$dir" >/dev/null 2>&1 || true; rm -f "$VPSG_TX_CURRENT"; return 30; fi
  log_event INFO "safe transaction started id=$id module=$module timeout=$timeout"; printf '%s\n' "$id"
}

tx_commit() {
  require_root || return 1
  local id="${1:-}" dir status module
  [[ -n "$id" ]] || id="$(_tx_current_id 2>/dev/null || true)"; [[ -n "$id" ]] || { error "没有 Safe Change 事务"; return 20; }
  dir="$(_tx_dir_for "$id")"; [[ -d "$dir" ]] || { error "事务不存在: $id"; return 20; }
  status="$(_tx_state_get "$dir" status)"; module="$(_tx_state_get "$dir" module)"; [[ "$status" == "pending" ]] || { error "事务状态为 $status，不能 commit"; return 30; }
  if ! _tx_postverify "$module"; then error "最终验证失败，拒绝 commit。建议 sudo vpsg safe rollback $id"; _tx_event "$dir" VERIFY_FAIL "commit refused"; return 50; fi
  _tx_event "$dir" VERIFY_OK "commit verification passed"; _tx_cancel_timer "$dir"; _tx_state_set "$dir" status committed; _tx_state_set "$dir" committed_epoch "$(date +%s)"; _tx_event "$dir" COMMIT "confirmed by administrator"
  [[ "$(_tx_current_id 2>/dev/null || true)" == "$id" ]] && rm -f "$VPSG_TX_CURRENT"
  log_event INFO "safe transaction committed id=$id"; ok "已确认事务 $id；自动回滚已取消。"
}

tx_manual_rollback() {
  require_root || return 1
  local id="${1:-}" dir status rc=0
  [[ -n "$id" ]] || id="$(_tx_current_id 2>/dev/null || true)"; [[ -n "$id" ]] || { error "没有 Safe Change 事务"; return 20; }
  dir="$(_tx_dir_for "$id")"; [[ -f "$dir/rollback.sh" ]] || { error "事务回滚脚本不存在"; return 20; }
  status="$(_tx_state_get "$dir" status)"; [[ "$status" == "pending" || "$status" == "apply_failed" ]] || { error "事务状态为 $status，不能回滚"; return 30; }
  _tx_event "$dir" ROLLBACK_REQUEST "manual"; _tx_cancel_timer "$dir"; /bin/bash "$dir/rollback.sh" || rc=$?
  [[ "$(_tx_current_id 2>/dev/null || true)" == "$id" ]] && rm -f "$VPSG_TX_CURRENT"; log_event INFO "safe transaction rollback id=$id rc=$rc"; return "$rc"
}

tx_status() {
  local id="${1:-}" dir status module deadline now remain
  [[ -n "$id" ]] || id="$(_tx_current_id 2>/dev/null || true)"; if [[ -z "$id" ]]; then echo "没有待确认的 Safe Change。"; return 0; fi
  dir="$(_tx_dir_for "$id")"; [[ -d "$dir" ]] || { warn "事务记录不存在: $id"; return 20; }
  status="$(_tx_state_get "$dir" status)"; module="$(_tx_state_get "$dir" module)"; deadline="$(_tx_state_get "$dir" deadline_epoch)"; now="$(date +%s)"; remain=0
  [[ "$deadline" =~ ^[0-9]+$ ]] && (( deadline > now )) && remain=$((deadline-now))
  printf '事务: %s\n模块: %s\n状态: %s\nSSH 端口: %s\n' "$id" "$module" "$status" "$(_tx_state_get "$dir" ssh_port)"
  if [[ "$status" == "pending" ]]; then printf '自动回滚剩余: %s 秒\n确认保留: sudo vpsg commit %s\n立即回滚: sudo vpsg safe rollback %s\n' "$remain" "$id" "$id"; fi
}

tx_history() {
  local limit="${1:-20}" d id status module created
  [[ "$limit" =~ ^[0-9]+$ ]] || limit=20
  [[ -d "$VPSG_TX_DIR" ]] || { echo "暂无 Safe Change 历史。"; return 0; }
  printf '%-23s %-10s %-15s %s\n' "TRANSACTION" "MODULE" "STATUS" "CREATED"
  find "$VPSG_TX_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -r | head -n "$limit" | while read -r id; do
    d="$VPSG_TX_DIR/$id"; status="$(_tx_state_get "$d" status)"; module="$(_tx_state_get "$d" module)"; created="$(_tx_state_get "$d" created_epoch)"
    [[ "$created" =~ ^[0-9]+$ ]] && created="$(date -d "@$created" '+%F %T' 2>/dev/null || echo "$created")"
    printf '%-23s %-10s %-15s %s\n' "$id" "$module" "$status" "$created"
  done
}

tx_show() {
  local id="${1:-}" dir
  [[ -n "$id" ]] || { error "用法: vpsg safe show <transaction-id>"; return 64; }
  dir="$(_tx_dir_for "$id")"; [[ -d "$dir" ]] || { error "事务不存在: $id"; return 20; }
  cat "$dir/state"; if [[ -r "$dir/events.log" ]]; then echo; echo "事件:"; cat "$dir/events.log"; fi; if [[ -r "$dir/rollback.log" ]]; then echo; echo "回滚日志:"; cat "$dir/rollback.log"; fi
}

tx_safe_apply() {
  require_root || return 1
  local module="${1:-}" action="${2:-}"; shift 2 2>/dev/null || true
  [[ "$action" == "apply" ]] || { error "用法: sudo vpsg safe <ssh|firewall> apply [--timeout 180] [--yes]"; return 64; }
  local timeout="$VPSG_TX_DEFAULT_TIMEOUT" args=() a id dir rc=0
  while (($#)); do a="$1"; case "$a" in --timeout) [[ $# -ge 2 ]] || return 64; timeout="$2"; shift 2;; *) args+=("$1"); shift;; esac; done
  id="$(tx_begin "$module" "$timeout")" || return $?; dir="$(_tx_dir_for "$id")"
  info "Safe Change 已启动：${timeout} 秒后若未 commit 将自动回滚。"; info "事务 ID: $id"
  route_module "$module" apply "${args[@]}"; rc=$?
  if (( rc != 0 )); then _tx_state_set "$dir" status apply_failed; _tx_event "$dir" APPLY_FAIL "rc=$rc"; error "应用失败，立即恢复事务快照。"; tx_manual_rollback "$id" >/dev/null 2>&1 || true; return "$rc"; fi
  if ! _tx_postverify "$module"; then _tx_state_set "$dir" status apply_failed; _tx_event "$dir" VERIFY_FAIL "post-apply"; error "修改后自检失败，立即自动回滚。"; tx_manual_rollback "$id" >/dev/null 2>&1 || true; return 50; fi
  _tx_state_set "$dir" status pending; _tx_event "$dir" APPLY_OK "post-apply verification passed"
  cat <<EOF_DONE

修改已应用，但尚未永久确认。
请保持当前 SSH 会话，并在新的终端重新连接服务器。
验证正常后执行：
  sudo vpsg commit $id
如果 ${timeout} 秒内没有确认，系统会自动恢复修改前状态。
EOF_DONE
}
