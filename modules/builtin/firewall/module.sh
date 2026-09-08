#!/usr/bin/env bash
set -uo pipefail
VPSG_ROOT="${VPSG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
. "$VPSG_ROOT/core/common.sh"
. "$VPSG_ROOT/core/platform.sh"
STATE="$VPSG_STATE_DIR/firewall-last.state"
ufw_active() { have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; }
rule_exists() { local p="$1"; have ufw && ufw status 2>/dev/null | grep -Eq "^${p}/tcp[[:space:]]+ALLOW"; }
state_get() { awk -F= -v k="$1" '$1==k {print substr($0,index($0,"=")+1)}' "$STATE" 2>/dev/null | tail -1; }
status() { if ! have ufw; then [[ "${1:-}" == "--brief" ]] && echo "未安装" || echo "UFW: 未安装"; return 0; fi; if ufw_active; then [[ "${1:-}" == "--brief" ]] && echo "运行中" || ufw status numbered; else [[ "${1:-}" == "--brief" ]] && echo "未启用" || ufw status; fi; }
plan() { local p; p="$(ssh_primary_port 2>/dev/null)" || { error "无法唯一确认 SSH 端口。为避免锁死连接，停止防火墙计划。"; return 30; }; cat <<PLAN
检测到 SSH 端口: $p/tcp
计划：保留现有规则，确保 SSH 端口允许，默认 incoming deny / outgoing allow，然后启用 UFW。
默认不会自动开放 80/443；如是 Web VPS，可执行 `sudo vpsg firewall web`。
PLAN
}
apply() { require_root || return 1; local p; p="$(ssh_primary_port 2>/dev/null)" || { error "无法确认 SSH 端口，拒绝启用 UFW"; return 30; }; plan || return $?; confirm "应用 UFW 防火墙配置？" || return 10; have ufw || apt_install ufw || return 40; ensure_runtime_dirs; local was_active=0 existed=0; ufw_active && was_active=1; rule_exists "$p" && existed=1; printf 'port=%s\nwas_active=%s\nrule_existed=%s\n' "$p" "$was_active" "$existed" > "$STATE"; ufw default deny incoming >/dev/null; ufw default allow outgoing >/dev/null; ((existed)) || ufw allow "$p/tcp" comment 'VPS Guard SSH' >/dev/null || return 40; ufw --force enable >/dev/null || return 40; verify || return 50; log_event INFO "ufw applied ssh_port=$p"; ok "UFW 已启用并保留 SSH 端口 $p/tcp"; }
verify() { local p; p="$(ssh_primary_port 2>/dev/null || true)"; [[ -n "$p" ]] || p="$(state_get port)"; ufw_active || return 1; rule_exists "$p" || return 1; ok "UFW 验证通过：$p/tcp 已放行"; }
rollback() { require_root || return 1; [[ -r "$STATE" ]] || return 20; local p was existed; p="$(state_get port)"; was="$(state_get was_active)"; existed="$(state_get rule_existed)"; valid_port "$p" || return 60; [[ "$existed" == 1 ]] || ufw --force delete allow "$p/tcp" >/dev/null 2>&1 || true; [[ "$was" == 1 ]] || ufw --force disable >/dev/null 2>&1 || true; ok "已回滚 VPS Guard 上次 UFW 修改"; }
allow_rule() { require_root || return 1; local p="${1:-}" proto="${2:-tcp}"; valid_port "$p" || { error "用法: sudo vpsg firewall allow <port> [tcp|udp]"; return 64; }; [[ "$proto" =~ ^(tcp|udp)$ ]] || return 64; have ufw || apt_install ufw || return 40; confirm "允许 $p/$proto 入站？" || return 10; ufw allow "$p/$proto" comment 'VPS Guard rule'; log_event INFO "ufw allow port=$p proto=$proto"; }
deny_rule() { require_root || return 1; local p="${1:-}" proto="${2:-tcp}" sshp; valid_port "$p" || return 64; sshp="$(ssh_primary_port 2>/dev/null || true)"; [[ "$p" != "$sshp" ]] || { error "拒绝阻断当前 SSH 端口 $p。请先迁移并验证 SSH。"; return 30; }; confirm "拒绝 $p/$proto 入站？" || return 10; ufw deny "$p/$proto"; log_event INFO "ufw deny port=$p proto=$proto"; }
delete_rule() { require_root || return 1; local p="${1:-}" proto="${2:-tcp}" sshp; valid_port "$p" || return 64; sshp="$(ssh_primary_port 2>/dev/null || true)"; [[ "$p" != "$sshp" ]] || { error "拒绝删除当前 SSH 端口规则"; return 30; }; confirm "删除 allow $p/$proto？" || return 10; ufw --force delete allow "$p/$proto"; log_event INFO "ufw delete allow port=$p proto=$proto"; }
web_profile() { require_root || return 1; have ufw || apt_install ufw || return 40; echo "将开放 Web 常用端口 80/tcp 和 443/tcp。"; confirm "继续？" || return 10; ufw allow 80/tcp comment 'VPS Guard HTTP'; ufw allow 443/tcp comment 'VPS Guard HTTPS'; ok "Web 端口已允许"; }
action="${1:-status}"; shift || true; parse_yes_flag "$@"
case "$action" in status|check|list) status "$@";; plan) plan;; apply) apply;; verify) verify;; rollback) rollback;; allow) allow_rule "$@";; deny) deny_rule "$@";; delete) delete_rule "$@";; web) web_profile;; doctor) plan >/dev/null && ok "UFW 前置检查通过" || exit 30;; *) error "firewall 支持: status|plan|apply|verify|rollback|allow|deny|delete|web"; exit 64;; esac
