#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(bash "$ROOT/bin/vpsg" --version)"
OUT="${1:-$ROOT/dist}"
SELF_TEST=0
[[ "${2:-}" == "--self-test" ]] && SELF_TEST=1

case "$VERSION" in
  ''|*[!0-9A-Za-z._-]*) printf 'Invalid version: %s\n' "$VERSION" >&2; exit 64 ;;
esac

STAGE_PARENT="$(mktemp -d)"
trap 'rm -rf -- "$STAGE_PARENT"' EXIT
PACKAGE="vps-guard-$VERSION"
STAGE="$STAGE_PARENT/$PACKAGE"
mkdir -p "$OUT" "$STAGE"

# Copy only release content. Development history, previous build output and
# editor/runtime debris never enter release archives.
tar -C "$ROOT" \
  --exclude='.git' \
  --exclude='./dist' \
  --exclude='*.swp' \
  --exclude='*~' \
  -cf - . | tar -C "$STAGE" -xf -

# Release payload must parse before it is archived.
find "$STAGE" -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
bash -n "$STAGE/bin/vpsg"
[[ "$(VPSG_ROOT="$STAGE" bash "$STAGE/bin/vpsg" --version)" == "$VERSION" ]]

TAR="$OUT/$PACKAGE.tar.gz"
ZIP="$OUT/$PACKAGE.zip"
rm -f -- "$TAR" "$ZIP" "$OUT/SHA256SUMS"

tar -C "$STAGE_PARENT" -czf "$TAR" "$PACKAGE"
(
  cd "$STAGE_PARENT"
  zip -qr "$ZIP" "$PACKAGE"
)
(
  cd "$OUT"
  sha256sum "$(basename "$TAR")" "$(basename "$ZIP")" > SHA256SUMS
  sha256sum -c SHA256SUMS
)

if ((SELF_TEST)); then
  for archive in "$TAR" "$ZIP"; do
    test_root="$(mktemp -d)"
    if [[ "$archive" == *.zip ]]; then
      unzip -q "$archive" -d "$test_root"
    else
      tar -xzf "$archive" -C "$test_root"
    fi
    extracted="$test_root/$PACKAGE"
    [[ "$(VPSG_ROOT="$extracted" bash "$extracted/bin/vpsg" --version)" == "$VERSION" ]]
    bash "$extracted/tests/run.sh"
    rm -rf -- "$test_root"
  done
fi

printf '%s\n' "$TAR" "$ZIP" "$OUT/SHA256SUMS"
