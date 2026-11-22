#!/usr/bin/env bash
# Scope helper for slices/<id>/verify.sh. Bash 3.2 compatible.
# slice_files [--allow-skip] BASE
#   Sets SLICE_FILES (newline list of paths changed by commits BASE..HEAD plus uncommitted changes)
#   and SLICE_ERROR. Returns 0 ok, 1 error, 3 BASE missing (only with --allow-skip).
# SLICE_UPSTREAM (optional, set by CI): a commit already checked, e.g. the PR merge commit's first parent or the
#   previous main tip on push. Then only non-merge commits in BASE..HEAD not reachable from it count, so changes that
#   reached main after BASE are not blamed on the slice. If slices/$SLICE_ID/SPEC.md is already status: done at
#   SLICE_UPSTREAM, the slice was scope-checked when it merged and SLICE_FILES is empty. All-zero means unset.
# Stacked slices: if slices/$SLICE_ID/SPEC.md is status: done and a commit in BASE..HEAD set it, the range ends at
#   that commit and uncommitted changes are ignored, so later slices on the same branch are not blamed on it.
# Squash landings: if that commit also carries another slice whose SPEC it touches and that is in_progress there or
#   set done in it too (so that slice's own verify.sh scope-checks this commit), the files of that commit inside the
#   other slice's paths_in_scope and outside its paths_out_of_scope are its, not this slice's, unless this slice also
#   changed them in an earlier commit of its range. Any other file this slice changed is still counted.
_slice_status() {  # status in the front-matter of the SPEC text on stdin
  awk 'NR==1 && $0!="---"{exit} NR>1 && $0=="---"{exit} NR>1{print}' \
    | sed -n 's/^status:[[:space:]]*//p' | sed 's/[[:space:]]*$//' | head -1
}
# _slice_done_commit BASE: newest commit in BASE..HEAD whose SPEC is done and whose first parent's is not.
_slice_done_commit() {
  local spec="slices/$SLICE_ID/SPEC.md" c
  for c in $(git log --no-merges --format=%H "$1..HEAD" -- "$spec" 2>/dev/null); do
    [ "$(git show "$c:$spec" 2>/dev/null | _slice_status)" = "done" ] || continue
    [ "$(git show "$c^:$spec" 2>/dev/null | _slice_status)" = "done" ] && continue
    echo "$c"; return 0
  done
}
# _slice_globs KEY: the list KEY in the front-matter of the SPEC text on stdin, as verify.sh reads it (** becomes *).
_slice_globs() {
  awk 'NR==1 && $0!="---"{exit} NR>1 && $0=="---"{exit} NR>1{print}' \
    | sed -n "s/^$1:[[:space:]]*//p" | head -1 | tr -d '[]' | tr ',' ' ' | sed 's#\*\*#*#g'
}
# _slice_co_landed C: sets SLICE_CO_LANDED (other slice ids landing in commit C, space separated) and
# SLICE_CO_LANDED_FILES (files changed in C in their paths_in_scope and not in their paths_out_of_scope, sorted).
_slice_co_landed() {
  local c="$1" changed other spec st inc exc p g hit out="" ids=""
  changed="$(git diff-tree --no-commit-id --no-renames --name-only -r "$c" 2>/dev/null)"
  for other in $(printf '%s\n' "$changed" | sed -n 's#^slices/\([^/]*\)/.*#\1#p' | LC_ALL=C sort -u); do
    [ "$other" = "$SLICE_ID" ] || [ "$other" = "_template" ] && continue
    spec="$(git show "$c:slices/$other/SPEC.md" 2>/dev/null)" || continue
    st="$(printf '%s\n' "$spec" | _slice_status)"
    case "$st" in
      in_progress) ;;
      done) [ "$(git show "$c^:slices/$other/SPEC.md" 2>/dev/null | _slice_status)" = "done" ] && continue ;;
      *) continue ;;
    esac
    inc="$(printf '%s\n' "$spec" | _slice_globs paths_in_scope)"
    exc="$(printf '%s\n' "$spec" | _slice_globs paths_out_of_scope)"
    ids="$ids${ids:+ }$other"
    set -f
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      hit=0
      for g in $inc; do case "$p" in $g) hit=1 ;; esac; done
      for g in $exc; do case "$p" in $g) hit=0 ;; esac; done
      [ $hit -eq 1 ] && out="$out$p
"
    done <<< "$changed"
    set +f
  done
  SLICE_CO_LANDED="$ids"
  SLICE_CO_LANDED_FILES="$(printf '%s' "$out" | grep -v '^$' | LC_ALL=C sort -u)"
  return 0
}
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
  local committed uncommitted="" end="HEAD" done_at
  if [ -n "$up" ]; then
    if ! git rev-parse --verify --quiet "$up^{commit}" >/dev/null; then
      SLICE_ERROR="SLICE_UPSTREAM $up not found"; return 1
    fi
    if [ -n "${SLICE_ID:-}" ] && [ "$(git show "$up:slices/$SLICE_ID/SPEC.md" 2>/dev/null | _slice_status)" = "done" ]; then
      echo "scope: $SLICE_ID was already done at SLICE_UPSTREAM; it was scope-checked when it merged"
      return 0
    fi
  fi
  if [ -n "${SLICE_ID:-}" ] && [ "$(_slice_status < "slices/$SLICE_ID/SPEC.md" 2>/dev/null)" = "done" ]; then
    done_at="$(_slice_done_commit "$base")"
    if [ -n "$done_at" ]; then
      end="$done_at"
      echo "scope: $SLICE_ID was set done in $(git rev-parse --short "$done_at"); checking $base..that commit"
    fi
  fi
  if [ -n "$up" ]; then
    committed="$(git log --no-merges --no-renames --name-only --format= "$base..$end" "^$up" 2>/dev/null)" \
      || { SLICE_ERROR="git log failed"; return 1; }
  else
    committed="$(git diff --no-renames --name-only "$base..$end" 2>/dev/null)" || { SLICE_ERROR="git diff failed"; return 1; }
  fi
  if [ "$end" != "HEAD" ]; then
    local theirs earlier
    _slice_co_landed "$end"; theirs="$SLICE_CO_LANDED_FILES"
    if [ -n "$theirs" ]; then
      if [ -n "$up" ]; then
        earlier="$(git log --no-merges --no-renames --name-only --format= "$base..$end^" "^$up" 2>/dev/null)"
      else
        earlier="$(git diff --no-renames --name-only "$base..$end^" 2>/dev/null)"
      fi
      # Drop the other slices' files unless this slice also changed them in an earlier commit.
      earlier="$(printf '%s\n' "$earlier" | grep -v '^$' | LC_ALL=C sort -u)"
      theirs="$(LC_ALL=C comm -23 <(printf '%s\n' "$theirs") <(printf '%s\n' "$earlier"))"
      committed="$(printf '%s\n' "$committed" | grep -v '^$' | LC_ALL=C sort -u)"
      committed="$(LC_ALL=C comm -23 <(printf '%s\n' "$committed") <(printf '%s\n' "$theirs"))"
      [ -n "$theirs" ] && echo "scope: that commit also lands $SLICE_CO_LANDED;" \
        "$(printf '%s\n' "$theirs" | grep -c .) of its path(s) are theirs (checked by their verify.sh), not $SLICE_ID's"
    fi
  fi
  if [ "$end" = "HEAD" ]; then
    uncommitted="$(git diff --no-renames --name-only HEAD 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null)"
  fi
  SLICE_FILES="$(printf '%s\n%s\n' "$committed" "$uncommitted" | grep -v '^$' | LC_ALL=C sort -u)"
  return 0
}
