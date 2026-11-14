#!/usr/bin/env bash
# Fails if any core code imports Enterprise (ee/) code.
# Core = apps/, packages/, services/. Enterprise = ee/ (package scope @offload-ee/*).
# ee/ may import core. Core may never import ee/. See docs/OPEN_CORE.md.
# Usage: scripts/check-license-boundary.sh [repo-root]
set -euo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"

CORE_DIRS=()
for d in apps packages services; do [[ -d $d ]] && CORE_DIRS+=("$d"); done
if [[ ${#CORE_DIRS[@]} -eq 0 ]]; then echo "license-boundary: no core dirs found under $ROOT" >&2; exit 2; fi

fail=0
# 1) Source imports: static import/export-from, dynamic import(), require().
pattern='(from[[:space:]]*|import[[:space:]]*\(?[[:space:]]*|require[[:space:]]*\([[:space:]]*)["'"'"'](@offload-ee/|[^"'"'"']*/ee/|ee/)'
if hits=$(grep -rnE --include='*.ts' --include='*.tsx' --include='*.js' --include='*.mjs' --include='*.cjs' \
  --exclude-dir=node_modules --exclude-dir=dist "$pattern" "${CORE_DIRS[@]}" 2>/dev/null); then
  echo "license-boundary: core source imports ee/ code:" >&2
  echo "$hits" >&2
  fail=1
fi
# 2) Manifests: core package.json must not depend on @offload-ee/*.
if hits=$(grep -rnE --include='package.json' --exclude-dir=node_modules '"@offload-ee/' "${CORE_DIRS[@]}" 2>/dev/null); then
  echo "license-boundary: core package.json depends on an @offload-ee package:" >&2
  echo "$hits" >&2
  fail=1
fi
# 3) tsconfig path tricks.
if hits=$(grep -rnE --include='tsconfig*.json' --exclude-dir=node_modules '(\.\./)+ee/' "${CORE_DIRS[@]}" 2>/dev/null); then
  echo "license-boundary: core tsconfig references ee/:" >&2
  echo "$hits" >&2
  fail=1
fi
if [[ $fail -ne 0 ]]; then exit 1; fi
echo "license-boundary: ok (core dirs: ${CORE_DIRS[*]})"
