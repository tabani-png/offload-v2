#!/usr/bin/env bash
# Product copy lint. Product surfaces must not say "dry run" (removed from the product,
# docs/adr/0016-no-dry-run.md) or use banned marketing words (docs/PRODUCT.md#copy-rules).
# Scope: user-visible copy files and app/web sources, plus the README tagline (first 5 lines).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BANNED='dry[ -]?run|generous|unlock|seamless|powerful|at scale|robust|everything you need'
fail=0
targets=()
for d in apps/mac/Sources apps/web/src packages/contracts/src/copy; do [[ -d $d ]] && targets+=("$d"); done
if [[ ${#targets[@]} -gt 0 ]]; then
  if hits=$(grep -rniE "$BANNED" "${targets[@]}" 2>/dev/null); then
    echo "copy: banned phrase in product copy:" >&2; echo "$hits" >&2; fail=1
  fi
fi
if head -n 5 README.md | grep -niE "$BANNED|—" >/dev/null; then
  echo "copy: README tagline uses a banned phrase or an em dash" >&2; fail=1
fi
[[ $fail -eq 0 ]] || exit 1
echo "copy: ok"
