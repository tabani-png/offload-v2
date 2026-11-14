#!/usr/bin/env bash
# m1-05-mac-capture-upload done-signal. Contract: slices/m1-05-mac-capture-upload/SPEC.md. Bash 3.2 compatible.
# Swift slice: runs only on macOS with Swift 6 (CI job "mac").
# 1. swift build  2. slice tests (>= MIN_TESTS, every tag present and passing)  3. full swift test  4. scope.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SLICE_ID="m1-05-mac-capture-upload"
BASE=""
PKG="apps/mac"
TEST_DIR="apps/mac/Tests/OffloadMacTests/M105"
MIN_TESTS=16
TAGS="NONET MASK EXCLUDE STORE UPLOAD"
OUT_OF_SCOPE_GLOBS="ee/* services/* packages/db/* apps/web/* docs/adr/*"

fails=0
fail() { echo "FAIL $*"; fails=$((fails + 1)); }
[ "$(uname -s)" = "Darwin" ] || { echo "FAIL $SLICE_ID needs macOS (run it in the CI mac job)"; exit 1; }
command -v swift >/dev/null 2>&1 || { echo "FAIL swift not on PATH"; exit 1; }

echo "== swift build"
(cd "$PKG" && swift build >/dev/null 2>&1) && echo "build ok" || fail "swift build"

echo "== slice tests"
[ -d "$TEST_DIR" ] || fail "$TEST_DIR does not exist"
n_tests="$(grep -rhoE '@Test\("[A-Z]+: ' "$TEST_DIR" 2>/dev/null | wc -l | tr -d ' ')"
[ "${n_tests:-0}" -ge "$MIN_TESTS" ] || fail "only ${n_tests:-0} tagged tests, need $MIN_TESTS"
for tag in $TAGS; do
  grep -rqE "@Test\(\"$tag: " "$TEST_DIR" 2>/dev/null || { fail "no test named \"$tag: ...\""; continue; }
done
out="$(cd "$PKG" && swift test --filter M105 2>&1)" || { echo "$out" | tail -20; fail "slice tests failed"; }

echo "== full swift test"
(cd "$PKG" && swift test >/dev/null 2>&1) || fail "full swift test"

echo "== scope"
. "$ROOT/scripts/lib/slice-changes.sh"
slice_files --allow-skip "$BASE"; scope_rc=$?
case $scope_rc in
  0) ;;
  3) echo "scope: SKIPPED ($SLICE_ERROR)" ;;
  *) fail "scope check could not run: $SLICE_ERROR" ;;
esac
if [ $scope_rc -eq 0 ]; then
  set -f
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    for g in $OUT_OF_SCOPE_GLOBS; do
      case "$p" in $g) fail "out-of-scope path changed: $p" ;; esac
    done
  done <<< "$SLICE_FILES"
  set +f
fi

[ "$fails" -eq 0 ] && echo "$SLICE_ID: PASS" || { echo "$SLICE_ID: $fails failing check(s)"; exit 1; }
