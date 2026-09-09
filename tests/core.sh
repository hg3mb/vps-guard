#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/testlib.sh"

case_help() ( new_case_env help >/dev/null; local out; out="$(bash "$ROOT/bin/vpsg" --help)"; assert_contains "$out" 'Safe Change' && assert_contains "$out" 'exposure scan' && assert_contains "$out" 'setup guide'; )
case_version() ( new_case_env version >/dev/null; assert_eq "$(bash "$ROOT/bin/vpsg" --version)" '0.4.0'; )
case_modules() ( new_case_env modules >/dev/null; local out m; out="$(bash "$ROOT/bin/vpsg" module list)"; for m in baseline bbr docker drift exposure fail2ban firewall incident network panel setup ssh swap system users watch; do [[ "$out" == *$'\n'"$m"$'\n'* || "$out" == "$m"$'\n'* || "$out" == *$'\n'"$m" || "$out" == "$m" ]] || return 1; done; )
case_module_metadata() ( new_case_env metadata >/dev/null; local d f id version entry; for d in "$ROOT"/modules/builtin/*; do f="$d/module.conf"; [[ -r "$f" ]] || return 1; id="$(awk -F= '$1=="id"{print $2}' "$f")"; version="$(awk -F= '$1=="version"{print $2}' "$f")"; entry="$(awk -F= '$1=="entry"{print $2}' "$f")"; [[ "$id" == "$(basename "$d")" && "$version" == 0.4.0 && "$entry" == module.sh ]] || return 1; grep -q '^actions=.' "$f" || return 1; done; )
case_syntax() ( new_case_env syntax >/dev/null; local f; while IFS= read -r -d '' f; do bash -n "$f" || return 1; done < <(find "$ROOT" -type f -name '*.sh' -print0); bash -n "$ROOT/bin/vpsg"; )
case_status() ( new_case_env status >/dev/null; local out rc=0; out="$(bash "$ROOT/bin/vpsg" status 2>&1)" || rc=$?; [[ $rc -eq 0 ]] && assert_contains "$out" 'VPS Guard 0.4.0'; )
case_router_no_exec() ( local base mode rc; new_case_env routerexec >/dev/null; base="$CASE_BASE"; mode="$(stat -c %a "$ROOT/modules/builtin/exposure/module.sh")"; chmod -x "$ROOT/modules/builtin/exposure/module.sh"; bash "$ROOT/bin/vpsg" exposure profile show >/dev/null 2>&1; rc=$?; chmod "$mode" "$ROOT/modules/builtin/exposure/module.sh"; [[ $rc -eq 0 ]]; )
case_router_traversal() ( new_case_env traversal >/dev/null; source_core; . "$ROOT/core/router.sh"; ! module_id_valid '../ssh' && ! module_id_valid 'ssh/../../x' && module_id_valid 'ssh'; )
case_path_normalize() ( new_case_env pathnorm >/dev/null; source_core; [[ "$(path_normalize_lexical '/var/lib/../log/./x')" == '/var/log/x' && "$(path_normalize_lexical '/tmp/a/../../etc')" == '/etc' ]]; )
case_safe_delete_guard() ( local base; new_case_env safedel >/dev/null; base="$CASE_BASE"; source_core; mkdir -p "$base/allowed/a"; touch "$base/allowed/a/file"; safe_rm_rf_within "$base/allowed/a" "$base/allowed" && [[ ! -e "$base/allowed/a" ]] && ! safe_rm_rf_within '/var/lib/..' '/var/lib' >/dev/null 2>&1; )

case_symlink_ancestor_guard() (
  local base outside
  new_case_env symlinkancestor >/dev/null; base="$CASE_BASE"; source_core
  mkdir -p "$base/real" "$base/trusted"; outside="$base/real"
  ln -s "$outside" "$base/trusted/link"
  path_has_symlink_component "$base/trusted/link/child" || return 1
  ! assert_no_symlink_components "$base/trusted/link/child" >/dev/null 2>&1
)
case_safe_delete_symlink_ancestor() (
  local base
  new_case_env delsymancestor >/dev/null; base="$CASE_BASE"; source_core
  mkdir -p "$base/allowed" "$base/outside/victim"; printf keep > "$base/outside/victim/file"
  ln -s "$base/outside" "$base/allowed/link"
  ! safe_rm_rf_within "$base/allowed/link/victim" "$base/allowed" >/dev/null 2>&1 || return 1
  [[ -f "$base/outside/victim/file" ]]
)
case_systemd_quote() ( new_case_env sdquote >/dev/null; source_core; [[ "$(systemd_quote_arg '/tmp/a b"c')" == '"/tmp/a b\"c"' ]] && ! systemd_quote_arg $'/tmp/a\nb' >/dev/null; )
case_runtime_symlink() ( local base; new_case_env runtime >/dev/null; base="$CASE_BASE"; source_core; mkdir -p "$base/real"; ln -s "$base/real" "$VPSG_STATE_DIR"; ! ensure_runtime_dirs >/dev/null 2>&1; )
case_download_valid() ( local base dest rc=0; new_case_env dlvalid >/dev/null; base="$CASE_BASE"; source_core; dest="$base/script"; make_mock "$base" curl <<'MOCK'
#!/usr/bin/env bash
out=''; while (($#)); do [[ "$1" == -o ]] && { out="$2"; shift 2; continue; }; shift; done
printf '#!/usr/bin/env bash\necho ok\n' > "$out"
MOCK
 download_bash_script_checked 'https://example.invalid/test.sh' "$dest" || rc=$?; [[ $rc -eq 0 && -s "$dest" ]] && bash -n "$dest"; )
case_download_html_rejected() ( local base dest; new_case_env dlhtml >/dev/null; base="$CASE_BASE"; source_core; dest="$base/script"; make_mock "$base" curl <<'MOCK'
#!/usr/bin/env bash
out=''; while (($#)); do [[ "$1" == -o ]] && { out="$2"; shift 2; continue; }; shift; done
printf '<html>Access denied</html>\n' > "$out"
MOCK
 ! download_bash_script_checked 'https://example.invalid/test.sh' "$dest" >/dev/null 2>&1 && [[ ! -e "$dest" ]]; )
case_download_symlink_rejected() ( local base dest target; new_case_env dlsymlink >/dev/null; base="$CASE_BASE"; source_core; target="$base/target"; dest="$base/script"; printf 'keep\n' > "$target"; ln -s "$target" "$dest"; make_mock "$base" curl <<'MOCK'
#!/usr/bin/env bash
out=''; while (($#)); do [[ "$1" == -o ]] && { out="$2"; shift 2; continue; }; shift; done
printf '#!/usr/bin/env bash\necho overwritten\n' > "$out"
MOCK
 ! download_bash_script_checked 'https://example.invalid/test.sh' "$dest" >/dev/null 2>&1 && [[ "$(cat "$target")" == keep ]]; )
case_download_http_rejected() ( local base; new_case_env dlhttp >/dev/null; base="$CASE_BASE"; source_core; ! download_bash_script_checked 'http://example.invalid/x.sh' "$base/x" >/dev/null 2>&1; )
case_durable_write_sync_failure() (
  local base dest rc=0
  new_case_env durablesync >/dev/null; base="$CASE_BASE"; source_core; dest="$base/state-file"
  make_mock "$base" sync <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
  printf 'critical-state\n' | atomic_write_file_durable "$dest" 600 >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 40 && -f "$dest" && "$(cat "$dest")" == critical-state ]]
)

run_test 'help surface' case_help
run_test 'version' case_version
run_test 'module discovery' case_modules
run_test 'module metadata v0.4' case_module_metadata
run_test 'bash syntax' case_syntax
run_test 'read-only status' case_status
run_test 'router without executable bit' case_router_no_exec
run_test 'router traversal protection' case_router_traversal
run_test 'lexical path normalization' case_path_normalize
run_test 'dangerous deletion guard' case_safe_delete_guard
run_test 'symlink ancestor path guard' case_symlink_ancestor_guard
run_test 'safe delete rejects symlink ancestor' case_safe_delete_symlink_ancestor
run_test 'systemd argument quoting' case_systemd_quote
run_test 'runtime symlink rejection' case_runtime_symlink
run_test 'checked script download' case_download_valid
run_test 'HTML script rejection' case_download_html_rejected
run_test 'download symlink destination rejection' case_download_symlink_rejected
run_test 'non-HTTPS script rejection' case_download_http_rejected
run_test 'durable state write detects sync failure' case_durable_write_sync_failure
