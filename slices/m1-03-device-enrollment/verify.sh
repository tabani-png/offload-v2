#!/usr/bin/env bash
# m1-03-device-enrollment done-signal. Contract: slices/m1-03-device-enrollment/SPEC.md. Bash 3.2 compatible.
# 1. typecheck  2. slice suite (>= MIN_TESTS, every tag present and passing)  3. full suite  4. scope.
# Prints one "FAIL ..." line per failing check, then "<id>: PASS" or exits 1.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# ---- CONFIG -------------------------------------------------------------
SLICE_ID="m1-03-device-enrollment"
BASE=""                                  # commit this slice stacks on (set when the slice starts)
TEST_DIR="services/api/tests/m1-03-device-enrollment"
MIN_TESTS=14
TAGS="ENROLL TOKEN SESSION AUDIT"
OUT_OF_SCOPE_GLOBS="ee/* apps/* services/brain/* services/builder/* services/runtime/* docs/adr/*"
# -------------------------------------------------------------------------

if [ "$SLICE_ID" = "_template" ]; then echo "_template: nothing to verify (copy this file into a slice)"; exit 0; fi

fails=0
fail() { echo "FAIL $*"; fails=$((fails + 1)); }

command -v bun >/dev/null 2>&1 || { echo "FAIL bun not on PATH"; exit 1; }
[ -d node_modules/typescript ] || bun install --frozen-lockfile >/dev/null 2>&1 || fail "bun install failed"

echo "== typecheck"
tsc_out="$(bunx tsc --noEmit -p tsconfig.json 2>&1)" && echo "typecheck ok" || { echo "$tsc_out" | head -20; fail "typecheck"; }

echo "== slice suite"
[ -d "$TEST_DIR" ] || fail "$TEST_DIR does not exist"
out="$(bun test "$TEST_DIR" 2>&1)"; code=$?
echo "$out" | grep -E "^ *[0-9]+ (pass|fail|skip)$|^Ran [0-9]+ tests" || true
[ $code -eq 0 ] || { echo "$out" | grep -E "\(fail\)|error:" | head -20; fail "slice tests exited $code"; }
ran="$(echo "$out" | sed -n 's/^Ran \([0-9][0-9]*\) tests.*/\1/p' | tail -1)"
[ "${ran:-0}" -ge "$MIN_TESTS" ] || fail "only ${ran:-0} tests ran, need $MIN_TESTS"
for tag in $TAGS; do
  grep -rqE "\(\"$tag: " "$TEST_DIR" 2>/dev/null || { fail "no test named \"$tag: ...\""; continue; }
  t="$(bun test "$TEST_DIR" -t "$tag: " 2>&1)"
  n="$(echo "$t" | sed -n 's/^ *\([0-9][0-9]*\) pass$/\1/p' | tail -1)"
  echo "$t" | grep -qE "^ *0 fail$" && [ "${n:-0}" -gt 0 ] && echo "$tag: $n passing" || fail "tests for $tag did not pass"
done

echo "== full suite"
all="$(bun test 2>&1)"; acode=$?
echo "$all" | grep -E "^Ran [0-9]+ tests" || true
[ $acode -eq 0 ] || fail "full suite exited $acode"

echo "== scope"
. "$ROOT/scripts/lib/slice-changes.sh"
slice_files --allow-skip "$BASE"; scope_rc=$?
case $scope_rc in
  0) ;;
  3) echo "scope: SKIPPED ($SLICE_ERROR)" ;;
  *) fail "scope check could not run: $SLICE_ERROR" ;;
esac
if [ $scope_rc -eq 0 ]; then
  set -f  # globs below are patterns, not filenames
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    for g in $OUT_OF_SCOPE_GLOBS; do
      case "$p" in $g) fail "out-of-scope path changed: $p" ;; esac
    done
  done <<< "$SLICE_FILES"
  set +f
  echo "scope checked ($(printf '%s\n' "$SLICE_FILES" | grep -c .) files)"
fi

[ "$fails" -eq 0 ] && echo "$SLICE_ID: PASS" || { echo "$SLICE_ID: $fails failing check(s)"; exit 1; }
