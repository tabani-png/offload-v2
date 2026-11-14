#!/usr/bin/env bash
# notarize.sh <Offload.app> <version>: notarizes and staples the app, then builds, signs, notarizes and staples
# Offload-<version>.dmg next to the app (DEPLOYMENT 3.5).
# Needs ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_P8 (release environment secrets, operator item O3); when any is absent
# prints "notarization: skipped (absent: <names>)" and exits 0. On non-macOS exits 1 with "notarization: needs macOS".
# The App Store Connect key is written to a temporary file with mode 0600 and removed in a trap. On a rejected
# submission the notary log is written to <out>/notary-log-<name>.json for the workflow to upload. Signing the disk
# image uses the temporary keychain sign.sh created. Bash 3.2. Never set -x.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
APP="${1:-}"
VERSION="${2:-}"
[ -n "$APP" ] && [ -n "$VERSION" ] || { echo "usage: notarize.sh <Offload.app> <version>" >&2; exit 2; }
echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "notarization: version must be MAJOR.MINOR.PATCH" >&2; exit 2; }

missing="$(absent_names ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8)"
if [ -n "$missing" ]; then echo "notarization: skipped (absent: $missing)"; exit 0; fi
if [ "$(packaging_os)" != "Darwin" ]; then echo "notarization: needs macOS" >&2; exit 1; fi

CODESIGN="${CODESIGN:-codesign}"
OUT="$(cd "$(dirname "$APP")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
umask 077
KEY="$work/AuthKey.p8"
printf '%s\n' "$ASC_KEY_P8" > "$KEY"
chmod 600 "$KEY"

# submit FILE NAME: waits for the notary service; on anything but Accepted saves the log and fails.
submit() {
  local file="$1" name="$2" result id status
  result="$(xcrun notarytool submit "$file" --key "$KEY" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" \
    --wait --output-format json)" || true
  id="$(printf '%s' "$result" | sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p' | head -1)"
  status="$(printf '%s' "$result" | sed -n 's/.*"status" *: *"\([^"]*\)".*/\1/p' | head -1)"
  echo "notarization: $name submission ${id:-none}: ${status:-no status}"
  if [ "$status" != "Accepted" ]; then
    if [ -n "$id" ]; then
      xcrun notarytool log "$id" --key "$KEY" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" \
        "$OUT/notary-log-$name.json" || true
    fi
    echo "notarization: $name was not accepted" >&2
    return 1
  fi
}

# 1. The app carries its own ticket.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$work/Offload-notarize.zip"
submit "$work/Offload-notarize.zip" app
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# 2. Disk image for first installs: the stapled app and an Applications shortcut.
IDENTITY="$(find_identity "$(signing_keychain)")"
[ -n "$IDENTITY" ] || { echo "notarization: no Developer ID identity (run sign.sh developer-id first)" >&2; exit 1; }
mkdir "$work/stage"
ditto "$APP" "$work/stage/Offload.app"
ln -s /Applications "$work/stage/Applications"
DMG="$OUT/Offload-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Offload" -srcfolder "$work/stage" -ov -format UDZO "$DMG" >/dev/null
"$CODESIGN" --force --options runtime --timestamp --keychain "$(signing_keychain)" --sign "$IDENTITY" "$DMG"
submit "$DMG" dmg
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
echo "notarization: $(basename "$APP") and $(basename "$DMG") notarized and stapled"
