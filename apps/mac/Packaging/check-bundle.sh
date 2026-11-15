#!/usr/bin/env bash
# check-bundle.sh <Offload.app>: the rules checked on every built bundle (DEPLOYMENT 3.1, release checklist 9):
#   no Mach-O under Resources/ (magic bytes, no `file` dependency); every executable passes
#   `${CODESIGN:-codesign} --verify --strict`; Resources/THIRD_PARTY_NOTICES.txt present; size within
#   BUNDLE_MAX_MB (default 50, the planning figure). One "bundle check: FAIL ..." line per problem. Bash 3.2.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
APP="${1:-}"
[ -n "$APP" ] && [ -d "$APP/Contents" ] || { echo "usage: check-bundle.sh <Offload.app>" >&2; exit 2; }
CODESIGN="${CODESIGN:-codesign}"
MAX_MB="${BUNDLE_MAX_MB:-50}"
echo "$MAX_MB" | grep -Eq '^[1-9][0-9]*$' || { echo "check-bundle: BUNDLE_MAX_MB must be a positive integer" >&2; exit 2; }
fails=0
fail() { echo "bundle check: FAIL $*"; fails=$((fails + 1)); }

# Mach-O magics: thin 32/64-bit either byte order, and universal (fat) headers.
is_macho() {
  local m
  m="$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')"
  case "$m" in feedface|feedfacf|cefaedfe|cffaedfe|cafebabe|bebafeca) return 0 ;; esac
  return 1
}

if [ -d "$APP/Contents/Resources" ]; then
  while IFS= read -r f; do
    is_macho "$f" && fail "Mach-O under Resources: ${f#$APP/}"
  done < <(find "$APP/Contents/Resources" -type f)
fi

[ -f "$APP/Contents/Resources/THIRD_PARTY_NOTICES.txt" ] || fail "missing Resources/THIRD_PARTY_NOTICES.txt"

if ! command -v "$CODESIGN" >/dev/null 2>&1; then
  fail "codesign not found"
else
  # Every file in MacOS/ and every Mach-O under Frameworks/ (nested helpers included), then the bundle itself.
  while IFS= read -r f; do
    if [ "${f#$APP/Contents/MacOS/}" != "$f" ] || is_macho "$f"; then
      "$CODESIGN" --verify --strict "$f" >/dev/null 2>&1 || fail "not signed or rejected by codesign: ${f#$APP/}"
    fi
  done < <(find "$APP/Contents/MacOS" "$APP/Contents/Frameworks" -type f 2>/dev/null)
  "$CODESIGN" --verify --strict "$APP" >/dev/null 2>&1 || fail "not signed or rejected by codesign: $(basename "$APP")"
fi

kb="$(du -sk "$APP" | cut -f1)"
[ "$kb" -le $((MAX_MB * 1024)) ] || fail "over the size budget: ${kb} KB > ${MAX_MB} MB"

if [ "$fails" -gt 0 ]; then exit 1; fi
echo "bundle check: ok ($((kb / 1024)) MB of $MAX_MB MB)"
