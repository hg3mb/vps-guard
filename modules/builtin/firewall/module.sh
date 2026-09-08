#!/usr/bin/env bash
set -uo pipefail
VPSG_ROOT="${VPSG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
. "$VPSG_ROOT/core/common.sh"
. "$VPSG_ROOT/core/platform.sh"
STATE="$VPSG_STATE_DIR/firewall-last.state"

ufw_active() { have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; }
rule_exists() {
  local p="$1"
  have ufw && ufw status 2>/dev/null | grep -Eq "^${p}/tcp[[:space:]]+ALLOW"
}
state_get() { awk -F= -v k="$1" '$1==k {print substr($0,index($0,"=")+1)}' "$STATE" 2>/dev/null | tail -1; }

status() {
  if ! have ufw; then [[ "${1:-}" == "--brief" ]] && echo "未安装" || echo "UFW: 未安装"; return 0; fi
  if ufw_active; then [[ "${1:-}" == "--brief" ]] && echo "运行中" || ufw status; else [[ "${1:-}" == "--brief" ]] && echo "未启用" || ufw status; fi
}

plan() {
  local p
  if ! p="$(ssh_primary_port 2>/dev/null)"; then
    error "无法唯一确认 SSH 端口。为避免锁死远程连接，停止防火墙计划。"
    return 30
  fi
  cat <<PLAN
检测到需要保留的 SSH 端口: $p/tcp
计划：
  1. 保留现有 UFW 规则
  2. 确保 $p/tcp 被允许
  3. 启用 UFW（默认 incoming deny / outgoing allow）
不会默认开放 80/443；应用后会验证 SSH 端口规则仍存在。
PLAN
}

apply() {
  require_root || return 1
  local p; p="$(ssh_primary_port 2>/dev/null)" || { error "无法确认 SSH 端口，拒绝启用 UFW"; return 30; }
  plan || return $?
  confirm "应用 UFW 防火墙配置？" || return 10
  have ufw || apt_install ufw || return 40
  ensure_runtime_dirs
  local was_active=0 existed=0
  ufw_active && was_active=1
  rule_exists "$p" && existed=1
  cat > "$STATE" <<STATEFILE
port=$p
was_active=$was_active
rule_existed=$existed
STATEFILE
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  if [[ "$existed" == "0" ]]; then ufw allow "$p/tcp" comment 'VPS Guard SSH' >/dev/null || return 40; fi
  ufw --force enable >/dev/null || return 40
  verify || { error "UFW 验证失败；请保持当前 SSH 会话"; return 50; }
  log_event INFO "ufw applied ssh_port=$p"
  ok "UFW 已启用并保留 SSH 端口 $p/tcp"
}

verify() {
  local p; p="$(ssh_primary_port 2>/dev/null || true)"
  [[ -n "$p" ]] || p="$(state_get port)"
  ufw_active || return 1
  rule_exists "$p" || return 1
  ok "UFW 验证通过：$p/tcp 已放行"
}

rollback() {
  require_root || return 1
  [[ -r "$STATE" ]] || { error "没有防火墙回滚状态"; return 20; }
  local p was existed
  p="$(state_get port)"; was="$(state_get was_active)"; existed="$(state_get rule_existed)"
  valid_port "$p" || return 60
  if [[ "$existed" == "0" ]]; then ufw --force delete allow "$p/tcp" >/dev/null 2>&1 || true; fi
  if [[ "$was" == "0" ]]; then ufw --force disable >/dev/null 2>&1 || true; fi
  log_event INFO "ufw rollback ssh_port=$p"
  ok "已回滚 VPS Guard 上次 UFW 修改"
}

action="${1:-status}"; shift || true
parse_yes_flag "$@"
case "$action" in
  status|check) status "$@" ;;
  plan) plan ;;
  apply) apply ;;
  verify) verify ;;
  rollback) rollback ;;
  doctor) plan >/dev/null && ok "UFW 前置检查通过" || exit 30 ;;
  *) error "firewall 支持: status|plan|apply|verify|rollback|doctor"; exit 64 ;;
esac
