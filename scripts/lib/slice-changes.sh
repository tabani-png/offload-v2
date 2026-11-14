#!/usr/bin/env bash
# Scope helper for slices/<id>/verify.sh. Bash 3.2 compatible.
# slice_files [--allow-skip] BASE
#   Sets SLICE_FILES (newline list of paths changed by commits BASE..HEAD plus uncommitted changes)
#   and SLICE_ERROR. Returns 0 ok, 1 error, 3 BASE missing (only with --allow-skip).
slice_files() {
  SLICE_FILES=""; SLICE_ERROR=""
  local allow_skip=0
  if [ "${1:-}" = "--allow-skip" ]; then allow_skip=1; shift; fi
  local base="${1:-}"
  if [ -z "$base" ]; then
    SLICE_ERROR="no BASE set"
    if [ $allow_skip -eq 1 ]; then return 3; fi
    return 1
  fi
  if ! git rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
    SLICE_ERROR="BASE $base not found"
    if [ $allow_skip -eq 1 ]; then return 3; fi
    return 1
  fi
  local committed uncommitted
  committed="$(git diff --no-renames --name-only "$base"..HEAD 2>/dev/null)" || { SLICE_ERROR="git diff failed"; return 1; }
  uncommitted="$(git diff --no-renames --name-only HEAD 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null)"
  SLICE_FILES="$(printf '%s\n%s\n' "$committed" "$uncommitted" | grep -v '^$' | sort -u)"
  return 0
}
