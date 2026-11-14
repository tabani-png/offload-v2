#!/usr/bin/env bash
# The harness. Run before every commit and in CI. Exit 0 = green.
# Steps: install, typecheck, tests, license boundary, slices lint, doc links, copy lint, secrets hygiene.
# Swift is built and tested only on macOS (CI job "mac"); on Linux it is reported as skipped.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
step() { printf '\n== %s\n' "$1"; }

step "bun install"
if [[ -f bun.lock ]]; then bun install --frozen-lockfile; else bun install; fi
step "typecheck (tsc --noEmit)"
bunx tsc --noEmit -p tsconfig.json
step "bun test"
bun test
step "license boundary"
bash scripts/check-license-boundary.sh
step "slices"
bash scripts/check-slices.sh
step "doc links"
bun scripts/check-doc-links.ts
step "product copy"
bash scripts/check-copy.sh
step "secrets hygiene"
bash scripts/check-secrets-hygiene.sh
step "swift (apps/mac)"
if [[ $(uname -s) == Darwin ]] && command -v swift >/dev/null; then
  (cd apps/mac && swift build && swift test)
else
  echo "skipped: needs macOS with Swift 6 (runs in CI job 'mac')"
fi
printf '\nverify-all: green\n'
