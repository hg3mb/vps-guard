#!/usr/bin/env bash
set -euo pipefail
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then echo "请使用 sudo ./uninstall.sh" >&2; exit 1; fi
rm -f /usr/local/bin/vpsg
rm -rf /usr/lib/vps-guard
printf '%s\n' "程序已卸载。为安全起见，/etc/vps-guard、/var/lib/vps-guard 和系统安全配置未自动删除。"
