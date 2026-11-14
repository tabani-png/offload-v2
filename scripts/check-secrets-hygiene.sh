#!/usr/bin/env bash
# Fails if a .env file other than .env.example is tracked or present, or if .env.example has a value.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
fail=0
while IFS= read -r f; do
  [[ $(basename "$f") == ".env.example" ]] && continue
  echo "secrets: unexpected env file $f" >&2; fail=1
done < <(find . -path ./node_modules -prune -o -path ./.git -prune -o -name '.env*' -type f -print)
if grep -nE '^[A-Z0-9_]+=.+' .env.example >/dev/null; then
  echo "secrets: .env.example must have empty values" >&2; fail=1
fi
[[ $fail -eq 0 ]] || exit 1
echo "secrets: ok"
