#!/usr/bin/env bash
# m3-13-mac-build-progress done-signal. Contract: slices/m3-13-mac-build-progress/SPEC.md. Bash 3.2 compatible.
# Swift slice: runs only on macOS with Swift 6 (CI job "mac"). Elsewhere it prints SKIPPED and exits 0, unless
# REQUIRE_MAC=1, which turns the skip into a failure.
# 1. scope (every platform)  2. swift build  3. suite M313 (>= min_tests passed, every red_tests tag has passing tests)  4. full swift test.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# ---- CONFIG -------------------------------------------------------------
SLICE_ID="m3-13-mac-build-progress"
BASE="da18c84cd0eac2d10db561dca829e88eb483217d"   # set to the commit this slice starts from (after m3-10 is done) when status becomes in_progress
PKG="apps/mac"
TEST_DIR="apps/mac/Tests/OffloadMacTests/M313"
SUITE="OffloadMacTests.M313"
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
# This branch stacks several slices, so BASE..HEAD holds other slices' commits. The
# scope check counts only commits whose subject starts with "$SLICE_ID: " (AGENTS commit rule), plus uncommitted
# changes. It runs on every platform; only the Swift steps need macOS.
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
  # Commits are matched on the subject line only (a body line starting with the slice id does not count).
  subjects="$(git log --format='%H%x09%s' "$BASE"..HEAD 2>/dev/null)"
  own=""
  for c in $(printf '%s\n' "$subjects" | awk -F'\t' -v p="$SLICE_ID: " 'index($2, p) == 1 { print $1 }'); do
    own="$own
$(git show --no-renames --format= --name-only "$c")"
  done
  # Another slice's commit must not change a path this slice owns (AGENTS: one writer per owned path).
  OWNS="$(list owns | sed 's#\*\*#*#g')"
  for c in $(printf '%s\n' "$subjects" | awk -F'\t' -v p="$SLICE_ID: " '$2 ~ /^m[0-9]+-[0-9][0-9]-[a-z0-9-]+: / && index($2, p) != 1 { print $1 }'); do
    set -f
    for p in $(git show --no-renames --format= --name-only "$c"); do
      for g in $OWNS; do
        case "$p" in $g) fail "commit $(git log -1 --format=%h "$c") of another slice changed owned path: $p" ;; esac
      done
    done
    set +f
  done
  uncommitted="$(git diff --no-renames --name-only HEAD 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null)"
  SLICE_FILES="$(printf '%s\n%s\n' "$own" "$uncommitted" | grep -v '^$' | sort -u)"
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

if [ "$(uname -s)" != "Darwin" ]; then
  if [ "${REQUIRE_MAC:-0}" = "1" ]; then echo "FAIL $SLICE_ID needs macOS and REQUIRE_MAC=1 is set"; exit 1; fi
  [ "$fails" -eq 0 ] || { echo "$SLICE_ID: $fails failing check(s)"; exit 1; }
  echo "$SLICE_ID: SKIPPED (needs macOS)"; exit 0
fi
command -v swift >/dev/null 2>&1 || { echo "FAIL swift not on PATH"; exit 1; }

echo "== swift build"
(cd "$PKG" && swift build >/dev/null 2>&1) && echo "build ok" || fail "swift build"

echo "== slice suite $SUITE"
[ -d "$TEST_DIR" ] || fail "$TEST_DIR does not exist"
grep -rqE 'struct M313' "$TEST_DIR" 2>/dev/null || fail "no @Suite struct M313 in $TEST_DIR"
out="$(cd "$PKG" && swift test --filter "$SUITE" 2>&1)"; code=$?
[ $code -eq 0 ] || { echo "$out" | tail -20; fail "slice tests exited $code"; }
# Swift Testing does not print a "passed" line for every test (CI run 43652387723 printed 14 of 64), so the count
# comes from the run's summary line, "Test run with N tests in M suites passed", which appears only when every test
# in the filter passed. Each tag must have declared tests and no failure line.
total="$(echo "$out" | sed -n 's/.*Test run with \([0-9][0-9]*\) tests\{0,1\} in .* passed.*/\1/p' | tail -1)"
declared="$(grep -rhoE '@Test\("[A-Z]+: ' "$TEST_DIR" 2>/dev/null | wc -l | tr -d ' ')"
echo "passed: ${total:-0} (declared in $TEST_DIR: $declared)"
[ -n "$total" ] || fail "no passing 'Test run with N tests' line"
[ "${total:-0}" -ge "${MIN_TESTS:-1}" ] || fail "only ${total:-0} tests passed, need $MIN_TESTS (an empty filter match passes vacuously)"
[ "${total:-0}" -ge "${declared:-0}" ] || fail "only ${total:-0} of $declared declared tests ran"
for tag in $TAGS; do
  n="$(grep -rhoE "@Test\(\"$tag: " "$TEST_DIR" 2>/dev/null | wc -l | tr -d ' ')"
  [ "${n:-0}" -gt 0 ] || { fail "no test named \"$tag: ...\""; continue; }
  bad="$(echo "$out" | grep -cE "Test \"$tag: .*\" (failed|recorded an issue)")"
  [ -n "$total" ] && [ "${bad:-0}" -eq 0 ] && echo "$tag: $n passing" || fail "tests for $tag did not pass"
done

echo "== full swift test"
(cd "$PKG" && swift test >/dev/null 2>&1) || fail "full swift test"

[ "$fails" -eq 0 ] && echo "$SLICE_ID: PASS" || { echo "$SLICE_ID: $fails failing check(s)"; exit 1; }
