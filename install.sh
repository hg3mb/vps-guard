#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "请使用 sudo ./install.sh" >&2
  exit 1
fi

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="/usr/lib/vps-guard"
BACKUP="/var/lib/vps-guard/install-backups/$(date +%Y%m%d-%H%M%S)"

if [[ -d "$DEST" ]]; then
  mkdir -p "$BACKUP"
  cp -a "$DEST" "$BACKUP/previous"
fi

TMP="$(mktemp -d /usr/lib/vps-guard.new.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
cp -a "$SRC"/. "$TMP"/
rm -rf "$TMP/.git" 2>/dev/null || true
find "$TMP" -type d -exec chmod 755 {} +
find "$TMP" -type f -name '*.sh' -exec chmod 755 {} +
chmod 755 "$TMP/bin/vpsg"

rm -rf "$DEST.old"
[[ ! -d "$DEST" ]] || mv "$DEST" "$DEST.old"
mv "$TMP" "$DEST"
ln -sfn "$DEST/bin/vpsg" /usr/local/bin/vpsg
mkdir -p /etc/vps-guard /var/lib/vps-guard/backups /var/log/vps-guard
chmod 700 /var/lib/vps-guard /var/lib/vps-guard/backups

echo "VPS Guard 0.3.0 安装完成。运行: vpsg"
