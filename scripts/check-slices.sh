#!/usr/bin/env bash
# Lints every slices/*/SPEC.md front-matter and its verify.sh, then runs verify.sh for slices marked status: done
# (with SKIP_FULL_SUITE=1, because verify-all already ran the full suite).
# Slices with status ready or in_progress have red tests by design and are not run here.
# Usage: check-slices.sh [ROOT]   (ROOT defaults to the repo; tests pass a fixture root)
set -euo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
REQUIRED=(id title milestone status depends_on parallel_safe human_gated model_tier size parallel_group owns
  verify min_tests paths_in_scope paths_out_of_scope red_tests)
# verify.sh must read these from the SPEC, never hard-code them (one source of truth).
CONFIG_LINES=('MIN_TESTS="$(fm min_tests)"' 'TAGS="$(list red_tests)"'
  "IN_SCOPE=\"\$(list paths_in_scope | sed 's#\\*\\*#*#g')\""
  "OUT_OF_SCOPE=\"\$(list paths_out_of_scope | sed 's#\\*\\*#*#g')\"")
fail=0; count=0
err() { echo "slices: $*" >&2; fail=1; }
val() { grep -E "^$1:" <<<"$2" | head -1 | sed -E "s/^$1:[[:space:]]*//; s/[[:space:]]+\$//"; }

ids=" "
for spec in slices/*/SPEC.md; do [[ -f $spec ]] && ids+="$(basename "$(dirname "$spec")") "; done

for spec in slices/*/SPEC.md; do
  [[ -f $spec ]] || continue
  dir=$(dirname "$spec"); name=$(basename "$dir")
  fm=$(awk 'NR==1 && $0!="---"{exit} NR>1 && $0=="---"{exit} NR>1{print}' "$spec")
  if [[ -z $fm ]]; then err "$spec has no front-matter"; continue; fi
  for key in "${REQUIRED[@]}"; do
    grep -qE "^${key}:" <<<"$fm" || err "$spec missing key '$key'"
  done
  id=$(val id "$fm")
  [[ $name == "_template" || $id == "$name" ]] || err "$spec id '$id' != folder '$name'"
  status=$(val status "$fm")
  case "$status" in template|ready|in_progress|done) ;; *) err "$spec bad status '$status'" ;; esac
  case "$(val model_tier "$fm")" in opus|sonnet|haiku) ;; *) err "$spec model_tier must be opus, sonnet or haiku" ;; esac
  case "$(val size "$fm")" in S|M|L) ;; *) err "$spec size must be S, M or L" ;; esac
  [[ -n $(val parallel_group "$fm") ]] || err "$spec parallel_group is empty"
  for k in owns depends_on paths_in_scope paths_out_of_scope red_tests; do
    [[ $(val "$k" "$fm") =~ ^\[.*\]$ ]] || err "$spec $k must be a [list]"
  done
  [[ $(val verify "$fm") == "bash slices/$name/verify.sh" ]] || err "$spec verify must be 'bash slices/$name/verify.sh'"
  for dep in $(val depends_on "$fm" | tr -d '[]' | tr ',' ' '); do
    [[ $ids == *" $dep "* ]] || err "$spec depends_on '$dep' is not a slice"
  done

  v="$dir/verify.sh"
  if [[ ! -x $v ]]; then err "$v missing or not executable"; continue; fi
  grep -qxF "SLICE_ID=\"$name\"" "$v" || err "$v SLICE_ID must be \"$name\""
  for line in "${CONFIG_LINES[@]}"; do
    grep -qF -- "$line" "$v" || err "$v must read ${line%%=*} from the SPEC ($line)"
  done
  for var in MIN_TESTS TAGS IN_SCOPE OUT_OF_SCOPE; do
    n=$(grep -cE "^[[:space:]]*${var}=" "$v" || true)
    [[ $n -le 1 ]] || err "$v assigns $var more than once (read it from the SPEC only)"
  done
  base=$(sed -n 's/^BASE="\([^"]*\)".*/\1/p' "$v" | head -1)
  if [[ ($status == in_progress || $status == done) && -z $base ]]; then
    err "$v BASE is empty but status is $status (set BASE to the commit the slice starts from)"
  fi

  if [[ $status == done && $fail -eq 0 ]]; then
    SKIP_FULL_SUITE=1 bash "$v" || err "$name verify.sh failed"
  fi
  count=$((count+1))
done
[[ $fail -eq 0 ]] || exit 1
echo "slices: ok ($count specs linted)"
