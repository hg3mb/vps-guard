#!/usr/bin/env bash

module_id_valid() { [[ "${1:-}" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]]; }
module_path() { module_id_valid "$1" || return 64; printf '%s/modules/builtin/%s/module.sh\n' "$VPSG_ROOT" "$1"; }

# Do not require the executable bit. GitHub web uploads and ZIP downloads can
# lose Unix mode bits; invoking modules through bash keeps source checkouts usable.
module_exists() { module_id_valid "$1" || return 1; [[ -f "$(module_path "$1")" ]]; }

module_list() {
  local d
  for d in "$VPSG_ROOT"/modules/builtin/*; do
    [[ -d "$d" && -f "$d/module.sh" ]] || continue
    basename "$d"
  done | sort
}

route_module() {
  local module="${1:-}" action="${2:-status}"
  shift 2 2>/dev/null || true
  if ! module_exists "$module"; then
    error "未知模块: $module"
    return 64
  fi
  /bin/bash "$(module_path "$module")" "$action" "$@"
}
