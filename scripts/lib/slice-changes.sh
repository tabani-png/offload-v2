#!/usr/bin/env bash
# Scope helper for slices/<id>/verify.sh. Bash 3.2 compatible.
# slice_files [--allow-skip] BASE
#   Sets SLICE_FILES (newline list of paths changed by commits BASE..HEAD plus uncommitted changes)
#   and SLICE_ERROR. Returns 0 ok, 1 error, 3 BASE missing (only with --allow-skip).
# SLICE_UPSTREAM (optional, set by CI): a commit already checked, e.g. the PR merge commit's first parent or the
#   previous main tip on push. Then only non-merge commits in BASE..HEAD not reachable from it count, so changes that
#   reached main after BASE are not blamed on the slice. If slices/$SLICE_ID/SPEC.md is already status: done at
#   SLICE_UPSTREAM, the slice was scope-checked when it merged and SLICE_FILES is empty. All-zero means unset.
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
  local up="${SLICE_UPSTREAM:-}"
  case "$up" in *[!0]*) ;; *) up="" ;; esac
  local committed uncommitted
  if [ -n "$up" ]; then
    if ! git rev-parse --verify --quiet "$up^{commit}" >/dev/null; then
      SLICE_ERROR="SLICE_UPSTREAM $up not found"; return 1
    fi
    if [ -n "${SLICE_ID:-}" ] && git show "$up:slices/$SLICE_ID/SPEC.md" 2>/dev/null \
      | awk 'NR==1 && $0!="---"{exit} NR>1 && $0=="---"{exit} NR>1{print}' | grep -qE '^status:[[:space:]]*done[[:space:]]*$'; then
      echo "scope: $SLICE_ID was already done at SLICE_UPSTREAM; it was scope-checked when it merged"
      return 0
    fi
    committed="$(git log --no-merges --no-renames --name-only --format= "$base..HEAD" "^$up" 2>/dev/null)" \
      || { SLICE_ERROR="git log failed"; return 1; }
  else
    committed="$(git diff --no-renames --name-only "$base"..HEAD 2>/dev/null)" || { SLICE_ERROR="git diff failed"; return 1; }
  fi
  uncommitted="$(git diff --no-renames --name-only HEAD 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null)"
  SLICE_FILES="$(printf '%s\n%s\n' "$committed" "$uncommitted" | grep -v '^$' | sort -u)"
  return 0
}
