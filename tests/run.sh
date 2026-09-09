#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vps-guard-release-tests.XXXXXX")"
export ROOT TEST_ROOT
trap 'rm -rf -- "$TEST_ROOT"' EXIT

pass=0 fail=0
for suite in core security modules installer; do
  out="$TEST_ROOT/$suite.out"
  if bash "$ROOT/tests/$suite.sh" >"$out" 2>&1; then rc=0; else rc=$?; fi
  cat "$out"
  p="$(grep -c '^PASS:' "$out" 2>/dev/null || true)"; f="$(grep -c '^FAIL:' "$out" 2>/dev/null || true)"
  pass=$((pass+p)); fail=$((fail+f))
  if ((rc!=0 && f==0)); then echo "FAIL: suite $suite aborted (rc=$rc)"; fail=$((fail+1)); fi
done
printf 'Tests: %d passed, %d failed\n' "$pass" "$fail"
((fail==0))
