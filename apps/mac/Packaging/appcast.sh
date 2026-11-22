#!/usr/bin/env bash
# appcast.sh <Offload-<version>.zip> <version> <beta|stable>: signs the Sparkle archive and writes its appcast item
# (DEPLOYMENT section 4). Needs SPARKLE_ED_PRIVATE_KEY (release environment secret, operator item O11) and
# OFFLOAD_DOWNLOADS_HOST (repository variable, O13); when either is absent prints "appcast: skipped (absent: <names>)"
# and exits 0 (the secret is checked first). On non-macOS exits 1 with "appcast: needs macOS" (Sparkle's tools are macOS binaries).
# Sparkle's tools come from the pinned release archive, checksum-verified (fetch-sparkle-tools.sh), unless
# SPARKLE_BIN points at an already verified copy. generate_appcast reads every archive in the zip's folder (put the
# last five releases there for deltas) and its appcast.xml, adds this item (sparkle:channel beta for tester items)
# and signs the feed. The private key reaches the tools on stdin (--ed-key-file -), never as an argument.
# Outputs next to the zip: appcast.xml and <zip>.signature.txt. Bash 3.2. Never set -x.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
ZIP="${1:-}"
VERSION="${2:-}"
CHANNEL="${3:-}"
[ -n "$ZIP" ] && [ -n "$VERSION" ] || { echo "usage: appcast.sh <zip> <version> <beta|stable>" >&2; exit 2; }
case "$CHANNEL" in beta|stable) ;; *) echo "usage: appcast.sh <zip> <version> <beta|stable>" >&2; exit 2 ;; esac
echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "appcast: version must be MAJOR.MINOR.PATCH" >&2; exit 2; }

# The secret first, then the public host: each absent input is named on its own skip line.
for need in SPARKLE_ED_PRIVATE_KEY OFFLOAD_DOWNLOADS_HOST; do
  missing="$(absent_names "$need")"
  if [ -n "$missing" ]; then echo "appcast: skipped (absent: $missing)"; exit 0; fi
done
if [ "$(packaging_os)" != "Darwin" ]; then echo "appcast: needs macOS" >&2; exit 1; fi
[ -f "$ZIP" ] || { echo "appcast: $ZIP not found" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
BIN="${SPARKLE_BIN:-$(bash "$HERE/fetch-sparkle-tools.sh" "$work/sparkle")}"
DIR="$(cd "$(dirname "$ZIP")" && pwd)"

printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$BIN/sign_update" --ed-key-file - "$ZIP" > "$ZIP.signature.txt"

channel_args=""
[ "$CHANNEL" = "beta" ] && channel_args="--channel beta"
# shellcheck disable=SC2086
printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$BIN/generate_appcast" --ed-key-file - $channel_args \
  --download-url-prefix "https://$OFFLOAD_DOWNLOADS_HOST/" --maximum-deltas 5 -o "$DIR/appcast.xml" "$DIR"
grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$DIR/appcast.xml" \
  || { echo "appcast: no item for $VERSION in appcast.xml" >&2; exit 1; }
echo "appcast: $VERSION added to appcast.xml ($CHANNEL)"
