#!/usr/bin/env bash
# m3-02-mac-capture-upload done-signal. Contract: slices/m3-02-mac-capture-upload/SPEC.md. Bash 3.2 compatible.
# Swift slice: runs only on macOS with Swift 6 (CI job "mac"). Elsewhere it prints SKIPPED and exits 0, unless
# REQUIRE_MAC=1, which turns the skip into a failure.
# 1. swift build  2. suite M302 (>= min_tests passed, every red_tests tag has passing tests)  3. full swift test  4. scope.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# ---- CONFIG -------------------------------------------------------------
SLICE_ID="m3-02-mac-capture-upload"
BASE="60c7c12418b6c804b48fa19b01cef9a3fc6445e9"                                  # commit this slice stacks on (required once status is in_progress)
PKG="apps/mac"
TEST_DIR="apps/mac/Tests/OffloadMacTests/M302"
SUITE="OffloadMacTests.M302"
# -------------------------------------------------------------------------

if [ "$(uname -s)" != "Darwin" ]; then
  if [ "${REQUIRE_MAC:-0}" = "1" ]; then echo "FAIL $SLICE_ID needs macOS and REQUIRE_MAC=1 is set"; exit 1; fi
  echo "$SLICE_ID: SKIPPED (needs macOS)"; exit 0
fi

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
command -v swift >/dev/null 2>&1 || { echo "FAIL swift not on PATH"; exit 1; }

echo "== swift build"
(cd "$PKG" && swift build >/dev/null 2>&1) && echo "build ok" || fail "swift build"

echo "== slice suite $SUITE"
[ -d "$TEST_DIR" ] || fail "$TEST_DIR does not exist"
grep -rqE 'struct M302' "$TEST_DIR" 2>/dev/null || fail "no @Suite struct M302 in $TEST_DIR"
out="$(cd "$PKG" && swift test --filter "$SUITE" 2>&1)"; code=$?
[ $code -eq 0 ] || { echo "$out" | tail -20; fail "slice tests exited $code"; }
# Swift Testing prints one line per test: ✔ Test "TAG: name" passed after ...
passed="$(echo "$out" | grep -cE 'Test "[A-Z]+: .*" passed')"
echo "passed: $passed"
[ "${passed:-0}" -ge "${MIN_TESTS:-1}" ] || fail "only ${passed:-0} tests passed, need $MIN_TESTS (an empty filter match passes vacuously)"
for tag in $TAGS; do
  grep -rqE "@Test\(\"$tag: " "$TEST_DIR" 2>/dev/null || { fail "no test named \"$tag: ...\""; continue; }
  n="$(echo "$out" | grep -cE "Test \"$tag: .*\" passed")"
  bad="$(echo "$out" | grep -cE "Test \"$tag: .*\" (failed|recorded an issue)")"
  [ "${n:-0}" -gt 0 ] && [ "${bad:-0}" -eq 0 ] && echo "$tag: $n passing" || fail "tests for $tag did not pass"
done

echo "== full swift test"
(cd "$PKG" && swift test >/dev/null 2>&1) || fail "full swift test"

echo "== scope"
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
fi

[ "$fails" -eq 0 ] && echo "$SLICE_ID: PASS" || { echo "$SLICE_ID: $fails failing check(s)"; exit 1; }
