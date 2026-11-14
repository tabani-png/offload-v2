#!/usr/bin/env bash
# promote.sh <appcast.xml> <promote|halt> <version>: edits the appcast (appcast-edit.ts) and signs the edited feed
# again with Sparkle's sign_update. promote: beta to stable with sparkle:phasedRolloutInterval (PHASED_INTERVAL
# seconds per group, default 86400; seven groups). halt: removes the item. Needs SPARKLE_ED_PRIVATE_KEY; when absent
# prints "promote: skipped (absent: SPARKLE_ED_PRIVATE_KEY)" and exits 0. On non-macOS exits 1 with
# "promote: needs macOS". The key reaches sign_update on stdin. Bash 3.2. Never set -x.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
FEED="${1:-}"
ACTION="${2:-}"
VERSION="${3:-}"
case "$ACTION" in promote|halt) ;; *) echo "usage: promote.sh <appcast.xml> <promote|halt> <version>" >&2; exit 2 ;; esac
[ -f "$FEED" ] && [ -n "$VERSION" ] || { echo "usage: promote.sh <appcast.xml> <promote|halt> <version>" >&2; exit 2; }

missing="$(absent_names SPARKLE_ED_PRIVATE_KEY)"
if [ -n "$missing" ]; then echo "promote: skipped (absent: $missing)"; exit 0; fi
if [ "$(packaging_os)" != "Darwin" ]; then echo "promote: needs macOS" >&2; exit 1; fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
BIN="${SPARKLE_BIN:-$(bash "$HERE/fetch-sparkle-tools.sh" "$work/sparkle")}"
bun "$HERE/appcast-edit.ts" "$FEED" "$ACTION" "$VERSION" "${PHASED_INTERVAL:-86400}"
# SURequireSignedFeed is on, so the edited feed must carry a fresh signature.
printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$BIN/sign_update" --ed-key-file - "$FEED" > /dev/null
echo "promote: $ACTION $VERSION done; feed signed again"
