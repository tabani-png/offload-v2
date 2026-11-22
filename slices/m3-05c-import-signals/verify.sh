#!/usr/bin/env bash
# m3-05c-import-signals done-signal. Contract: slices/m3-05c-import-signals/SPEC.md. Bash 3.2 compatible.
# Every platform: 1. scope  2. the TypeScript TABLE tests (packages/contracts/tests/m3-05c-import-signals).
# macOS with Swift 6 only (CI job "mac"): 3. swift build  4. suite M305C (>= min_tests passed, every red_tests tag has
# passing tests)  5. full swift test. Elsewhere the Swift part prints SKIPPED, unless REQUIRE_MAC=1 (then it fails).
# SKIP_FULL_SUITE=1 skips step 5.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# ---- CONFIG -------------------------------------------------------------
SLICE_ID="m3-05c-import-signals"
BASE="9f17bed"   # commit this slice starts from (main at the chain start)
PKG="apps/mac"
TEST_DIR="apps/mac/Tests/OffloadMacTests/M305C"
SUITE="OffloadMacTests.M305C"
TEST_DIRS="packages/contracts/tests/m3-05c-import-signals"
NEEDS_POSTGRES=0
# -------------------------------------------------------------------------

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

echo "== scope"
# Only commits whose subject starts with "$SLICE_ID: " (AGENTS commit rule) count, plus uncommitted changes, so a
# branch that stacks other slices on this one does not charge their files here.
. "$ROOT/scripts/lib/slice-changes.sh"
case "$STATUS" in
  in_progress|done) slice_files "$BASE"; scope_rc=$? ;;
  *) slice_files --allow-skip "$BASE"; scope_rc=$? ;;
esac
case $scope_rc in
  0) ;;
  3) echo "scope: SKIPPED ($SLICE_ERROR; allowed only while status is $STATUS)" ;;
  *) fail "scope check could not run: $SLICE_ERROR (set BASE when status is in_progress)" ;;
esac
if [ $scope_rc -eq 0 ]; then
  if [ -n "$SLICE_FILES" ]; then
    subjects="$(git log --format='%H%x09%s' "$BASE"..HEAD 2>/dev/null)"
    own=""
    for c in $(printf '%s\n' "$subjects" | awk -F'\t' -v p="$SLICE_ID: " 'index($2, p) == 1 { print $1 }'); do
      own="$own
$(git show --no-renames --format= --name-only "$c")"
    done
    uncommitted="$(git diff --no-renames --name-only HEAD 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null)"
    # Keep only files slice_files also reports (it honours SLICE_UPSTREAM and a done SPEC's range).
    mine="$(printf '%s\n%s\n' "$own" "$uncommitted" | grep -v '^$' | sort -u)"
    SLICE_FILES="$(printf '%s\n' "$SLICE_FILES" | grep -v '^$' | sort -u | comm -12 - <(printf '%s\n' "$mine"))"
  fi
  set -f
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

echo "== TypeScript TABLE tests"
if ! command -v bun >/dev/null 2>&1; then
  fail "bun not on PATH"
else
  [ -d node_modules/zod ] || [ -d packages/contracts/node_modules/zod ] || bun install --frozen-lockfile >/dev/null 2>&1 || fail "bun install failed"
  for d in $TEST_DIRS; do [ -d "$d" ] || fail "$d does not exist"; done
  t="$(bun test $TEST_DIRS -t "TABLE: " 2>&1)"
  n="$(echo "$t" | sed -n 's/^ *\([0-9][0-9]*\) pass$/\1/p' | tail -1)"
  grep -rqE '\("TABLE: ' $TEST_DIRS 2>/dev/null || fail "no TypeScript test named \"TABLE: ...\""
  echo "$t" | grep -qE "^ *0 fail$" && [ "${n:-0}" -gt 0 ] && echo "TABLE (TypeScript): $n passing" || {
    echo "$t" | grep -E "\(fail\)|error:" | head -20; fail "TypeScript TABLE tests did not pass"; }
fi

if [ "$(uname -s)" != "Darwin" ]; then
  if [ "${REQUIRE_MAC:-0}" = "1" ]; then echo "FAIL $SLICE_ID needs macOS and REQUIRE_MAC=1 is set"; exit 1; fi
  [ "$fails" -eq 0 ] || { echo "$SLICE_ID: $fails failing check(s)"; exit 1; }
  echo "$SLICE_ID: SKIPPED (Swift needs macOS; scope and TypeScript checks passed)"; exit 0
fi
command -v swift >/dev/null 2>&1 || { echo "FAIL swift not on PATH"; exit 1; }

echo "== swift build"
(cd "$PKG" && swift build >/dev/null 2>&1) && echo "build ok" || fail "swift build"

echo "== slice suite $SUITE"
[ -d "$TEST_DIR" ] || fail "$TEST_DIR does not exist"
grep -rqE 'struct M305C' "$TEST_DIR" 2>/dev/null || fail "no @Suite struct M305C in $TEST_DIR"
out="$(cd "$PKG" && swift test --filter "$SUITE" 2>&1)"; code=$?
[ $code -eq 0 ] || { echo "$out" | tail -20; fail "slice tests exited $code"; }
# The count comes from the summary line "Test run with N tests in M suites passed" (Swift Testing does not print
# every passing test), which appears only when every test in the filter passed.
total="$(echo "$out" | sed -n 's/.*Test run with \([0-9][0-9]*\) tests\{0,1\} in .* passed.*/\1/p' | tail -1)"
declared="$(grep -rhoE '@Test\("[A-Z]+: ' "$TEST_DIR" 2>/dev/null | wc -l | tr -d ' ')"
echo "passed: ${total:-0} (declared in $TEST_DIR: $declared)"
[ -n "$total" ] || fail "no passing 'Test run with N tests' line"
[ "${total:-0}" -ge "${MIN_TESTS:-1}" ] || fail "only ${total:-0} tests passed, need $MIN_TESTS"
[ "${total:-0}" -ge "${declared:-0}" ] || fail "only ${total:-0} of $declared declared tests ran"
for tag in $TAGS; do
  n="$(grep -rhoE "@Test\(\"$tag: " "$TEST_DIR" 2>/dev/null | wc -l | tr -d ' ')"
  [ "${n:-0}" -gt 0 ] || { fail "no Swift test named \"$tag: ...\""; continue; }
  bad="$(echo "$out" | grep -cE "Test \"$tag: .*\" (failed|recorded an issue)")"
  [ -n "$total" ] && [ "${bad:-0}" -eq 0 ] && echo "$tag: $n passing" || fail "tests for $tag did not pass"
done

echo "== full swift test"
if [ "${SKIP_FULL_SUITE:-0}" = "1" ]; then
  echo "full swift test: skipped (SKIP_FULL_SUITE=1)"
else
  (cd "$PKG" && swift test >/dev/null 2>&1) || fail "full swift test"
fi

[ "$fails" -eq 0 ] && echo "$SLICE_ID: PASS" || { echo "$SLICE_ID: $fails failing check(s)"; exit 1; }
