#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(bash "$ROOT/bin/vpsg" --version)"
OUT="${1:-$ROOT/dist}"
mkdir -p "$OUT"
ARCHIVE="$OUT/vps-guard-${VERSION}.tar.gz"
tar --exclude='.git' --exclude='./dist' -C "$ROOT/.." -czf "$ARCHIVE" "$(basename "$ROOT")"
(cd "$OUT" && sha256sum "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256")
printf '%s\n' "$ARCHIVE" "$ARCHIVE.sha256"
