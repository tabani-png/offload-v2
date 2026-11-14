#!/usr/bin/env bash
# p45b-measured-saving done-signal. Contract: slices/p45b-measured-saving/SPEC.md. Bash 3.2 compatible.
# 1. typecheck  2. slice suite (>= min_tests, every red_tests tag present and passing)  3. full suite  4. scope.
# Prints one "FAIL ..." line per failing check, then "<id>: PASS" or exits 1.
# Copy to slices/<id>/verify.sh and edit the CONFIG block only. min_tests, red_tests, paths_in_scope and
# paths_out_of_scope are read from the SPEC front-matter, so the SPEC is the one source.
# Test names must be written test("TAG: ...") with double quotes; backticks or it( are not found.
# SKIP_FULL_SUITE=1 skips step 3 (set by callers that already ran the full suite).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# ---- CONFIG -------------------------------------------------------------
SLICE_ID="p45b-measured-saving"
BASE="724dbd3"                                # commit this slice stacks on (required once status is in_progress)
TEST_DIRS="packages/hours-saved/tests/p45b-measured-saving"   # one or more folders, space separated
NEEDS_POSTGRES=0                         # 1 = tests need a real Postgres 17 at DATABASE_URL
# -------------------------------------------------------------------------

if [ "$SLICE_ID" = "_template" ]; then echo "_template: nothing to verify (copy this file into a slice)"; exit 0; fi

SPEC="slices/$SLICE_ID/SPEC.md"
fm() { awk 'NR==1 && $0!="---"{exit} NR>1 && $0=="---"{exit} NR>1{print}' "$SPEC" | sed -n "s/^$1:[[:space:]]*//p" | head -1; }
list() { fm "$1" | tr -d '[]' | tr ',' ' '; }
MIN_TESTS="$(fm min_tests)"
TAGS="$(list red_tests)"
STATUS="$(fm status)"
IN_SCOPE="$(list paths_in_scope | sed 's#\*\*#*#g')"
OUT_OF_SCOPE="$(list paths_out_of_scope | sed 's#\*\*#*#g')"

fails=0
fail() { echo "FAIL $*"; fails=$((fails + 1)); }

command -v bun >/dev/null 2>&1 || { echo "FAIL bun not on PATH"; exit 1; }
[ -d node_modules/typescript ] || bun install --frozen-lockfile >/dev/null 2>&1 || fail "bun install failed"
if [ "$NEEDS_POSTGRES" = "1" ] && [ -z "${DATABASE_URL:-}" ]; then
  echo "FAIL DATABASE_URL not set ($SLICE_ID needs Postgres 17: docker compose -f infra/docker-compose/compose.yaml up -d)"
  exit 1
fi

echo "== typecheck"
tsc_out="$(bunx tsc --noEmit -p tsconfig.json 2>&1)" && echo "typecheck ok" || { echo "$tsc_out" | head -20; fail "typecheck"; }

echo "== slice suite"
for d in $TEST_DIRS; do [ -d "$d" ] || fail "$d does not exist"; done
out="$(bun test $TEST_DIRS 2>&1)"; code=$?
echo "$out" | grep -E "^ *[0-9]+ (pass|fail|skip)$|^Ran [0-9]+ tests" || true
[ $code -eq 0 ] || { echo "$out" | grep -E "\(fail\)|error:" | head -20; fail "slice tests exited $code"; }
ran="$(echo "$out" | sed -n 's/^Ran \([0-9][0-9]*\) tests.*/\1/p' | tail -1)"
[ "${ran:-0}" -ge "${MIN_TESTS:-1}" ] || fail "only ${ran:-0} tests ran, need $MIN_TESTS"
for tag in $TAGS; do
  grep -rqE "\(\"$tag: " $TEST_DIRS 2>/dev/null || { fail "no test named \"$tag: ...\""; continue; }
  t="$(bun test $TEST_DIRS -t "$tag: " 2>&1)"
  n="$(echo "$t" | sed -n 's/^ *\([0-9][0-9]*\) pass$/\1/p' | tail -1)"
  echo "$t" | grep -qE "^ *0 fail$" && [ "${n:-0}" -gt 0 ] && echo "$tag: $n passing" || fail "tests for $tag did not pass"
done

echo "== full suite"
if [ "${SKIP_FULL_SUITE:-0}" = "1" ]; then
  echo "full suite: skipped (SKIP_FULL_SUITE=1)"
else
  all="$(bun test 2>&1)"; acode=$?
  echo "$all" | grep -E "^Ran [0-9]+ tests" || true
  [ $acode -eq 0 ] || fail "full suite exited $acode"
fi

echo "== scope"
. "$ROOT/scripts/lib/slice-changes.sh"
case "$STATUS" in
  in_progress|done) slice_files "$BASE"; scope_rc=$? ;;   # BASE is required: no silent skip
  *) slice_files --allow-skip "$BASE"; scope_rc=$? ;;
esac
case $scope_rc in
  0) ;;
  3) echo "scope: SKIPPED ($SLICE_ERROR; allowed only while status is $STATUS)" ;;
  *) fail "scope check could not run: $SLICE_ERROR (set BASE when status is in_progress)" ;;
esac
if [ $scope_rc -eq 0 ]; then
  set -f  # globs below are patterns, not filenames
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    for g in $OUT_OF_SCOPE; do
      case "$p" in $g) fail "out-of-scope path changed: $p" ;; esac
    done
    hit=0
    for g in $IN_SCOPE; do
      case "$p" in $g) hit=1 ;; esac
    done
    [ $hit -eq 1 ] || fail "path not in paths_in_scope changed: $p"
  done <<< "$SLICE_FILES"
  set +f
  echo "scope checked ($(printf '%s\n' "$SLICE_FILES" | grep -c .) files)"
fi

[ "$fails" -eq 0 ] && echo "$SLICE_ID: PASS" || { echo "$SLICE_ID: $fails failing check(s)"; exit 1; }
