#!/usr/bin/env bash

module_path() { printf '%s/modules/builtin/%s/module.sh\n' "$VPSG_ROOT" "$1"; }

module_exists() { [[ -x "$(module_path "$1")" ]]; }

module_list() {
  local d
  for d in "$VPSG_ROOT"/modules/builtin/*; do
    [[ -d "$d" && -x "$d/module.sh" ]] || continue
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
  "$(module_path "$module")" "$action" "$@"
}
