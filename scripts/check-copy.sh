#!/usr/bin/env bash
# Product copy lint: no dry-run terms in product sources (ADR 0016); no banned marketing words or em dashes in
# user-visible strings (docs/PRODUCT.md#copy-rules). Implementation and scope: scripts/check-copy.ts.
# Usage: check-copy.sh [ROOT]
set -euo pipefail
exec bun "$(cd "$(dirname "$0")" && pwd)/check-copy.ts" "$@"
