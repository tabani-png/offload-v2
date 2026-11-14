#!/usr/bin/env bash
# Lints every slices/*/SPEC.md front-matter and runs verify.sh for slices marked status: done.
# Slices with status ready or in_progress have red tests by design and are not run here.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
REQUIRED=(id title milestone status depends_on parallel_safe human_gated verify min_tests paths_in_scope paths_out_of_scope red_tests)
fail=0; count=0
for spec in slices/*/SPEC.md; do
  [[ -f $spec ]] || continue
  dir=$(dirname "$spec"); name=$(basename "$dir")
  fm=$(awk 'NR==1 && $0!="---"{exit} NR>1 && $0=="---"{exit} NR>1{print}' "$spec")
  if [[ -z $fm ]]; then echo "slices: $spec has no front-matter" >&2; fail=1; continue; fi
  for key in "${REQUIRED[@]}"; do
    if ! grep -qE "^${key}:" <<<"$fm"; then echo "slices: $spec missing key '$key'" >&2; fail=1; fi
  done
  id=$(grep -E '^id:' <<<"$fm" | sed -E 's/^id:[[:space:]]*//')
  if [[ $name != "_template" && $id != "$name" ]]; then echo "slices: $spec id '$id' != folder '$name'" >&2; fail=1; fi
  [[ -x $dir/verify.sh ]] || { echo "slices: $dir/verify.sh missing or not executable" >&2; fail=1; }
  status=$(grep -E '^status:' <<<"$fm" | sed -E 's/^status:[[:space:]]*//')
  case "$status" in
    template|ready|in_progress|done) ;;
    *) echo "slices: $spec bad status '$status'" >&2; fail=1 ;;
  esac
  if [[ $status == done ]]; then
    bash "$dir/verify.sh" || { echo "slices: $name verify.sh failed" >&2; fail=1; }
  fi
  count=$((count+1))
done
[[ $fail -eq 0 ]] || exit 1
echo "slices: ok ($count specs linted)"
