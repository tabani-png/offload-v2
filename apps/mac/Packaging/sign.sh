#!/usr/bin/env bash
# sign.sh <Offload.app> <adhoc|developer-id>: signs inside-out (DEPLOYMENT 3.4), never --deep.
#   Order: Sparkle's XPC services removed (the app is not sandboxed), then Sparkle's nested helpers one by one
#   (Autoupdate, Updater.app), then Sparkle.framework, then Offload.app with Offload.entitlements.
#   Every codesign call uses the hardened runtime and a timestamp (adhoc: --timestamp=none, an ad hoc signature
#   cannot be timestamped; adhoc is for PR CI only, release builds are never ad hoc signed).
# developer-id needs DEVELOPER_ID_P12_BASE64 and DEVELOPER_ID_P12_PASSWORD (release environment secrets, operator
#   item O3). When either is absent: prints "signing: skipped (absent: <names>)" and exits 0. On non-macOS it exits 1
#   with "signing: needs macOS" before reading any value. Otherwise it creates a temporary keychain (see lib.sh
#   signing_keychain; release-mac.yml deletes it in a step that always runs) and imports the certificate.
#   APPLE_TEAM_ID (public repository variable), when set, must match the imported identity.
# Secret values are never echoed and never put on a command line, except the p12 password for `security import`,
# which has no stdin or file option. Bash 3.2. Never set -x.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
APP="${1:-}"
MODE="${2:-}"
case "$MODE" in adhoc|developer-id) ;; *) echo "usage: sign.sh <Offload.app> <adhoc|developer-id>" >&2; exit 2 ;; esac
[ -n "$APP" ] && [ -d "$APP/Contents" ] || { echo "usage: sign.sh <Offload.app> <adhoc|developer-id>" >&2; exit 2; }
CODESIGN="${CODESIGN:-codesign}"
ENTITLEMENTS="$HERE/Offload.entitlements"
FW="$APP/Contents/Frameworks/Sparkle.framework"

if [ "$MODE" = "developer-id" ]; then
  missing="$(absent_names DEVELOPER_ID_P12_BASE64 DEVELOPER_ID_P12_PASSWORD)"
  if [ -n "$missing" ]; then echo "signing: skipped (absent: $missing)"; exit 0; fi
  if [ "$(packaging_os)" != "Darwin" ]; then echo "signing: needs macOS" >&2; exit 1; fi

  KC="$(signing_keychain)"
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  umask 077
  KC_PASS="$(openssl rand -hex 24)"   # protects the throwaway keychain only; not a stored secret
  printf '%s' "$DEVELOPER_ID_P12_BASE64" | base64 --decode > "$work/developer-id.p12"
  security delete-keychain "$KC" >/dev/null 2>&1 || true
  security create-keychain -p "$KC_PASS" "$KC" >/dev/null
  security set-keychain-settings -lut 21600 "$KC"
  security unlock-keychain -p "$KC_PASS" "$KC" >/dev/null
  security import "$work/developer-id.p12" -k "$KC" -f pkcs12 -P "$DEVELOPER_ID_P12_PASSWORD" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KC" >/dev/null
  # Put the keychain on the search list so codesign (and notarize.sh for the disk image) find the identity.
  existing="$(security list-keychains -d user | tr -d '"' | tr '\n' ' ')"
  # shellcheck disable=SC2086
  security list-keychains -d user -s "$KC" $existing
  rm -f "$work/developer-id.p12"
  IDENTITY="$(find_identity "$KC")"
  [ -n "$IDENTITY" ] || { echo "signing: no Developer ID Application identity in the certificate" >&2; exit 1; }
  if [ -n "${APPLE_TEAM_ID:-}" ]; then
    security find-identity -v -p codesigning "$KC" | grep -q "($APPLE_TEAM_ID)\"" \
      || { echo "signing: the certificate's Team ID does not match APPLE_TEAM_ID" >&2; exit 1; }
  fi
  TS=""
  KC_ARGS="--keychain $KC"
else
  IDENTITY="-"
  TS="=none"
  KC_ARGS=""
fi

# One signing call, used for every target. Inside-out order is the caller's job (below).
sign_one() {
  local target="$1"; shift
  # shellcheck disable=SC2086
  "$CODESIGN" --force --options runtime --timestamp$TS $KC_ARGS --sign "$IDENTITY" "$@" "$target"
}

if [ -d "$FW" ]; then
  # The app is not sandboxed, so Sparkle's XPC services are not needed; remove them before signing.
  rm -rf "$FW/Versions/B/XPCServices" "$FW/XPCServices"
  sign_one "$FW/Versions/B/Autoupdate"
  sign_one "$FW/Versions/B/Updater.app"
  sign_one "$FW"
fi
sign_one "$APP" --entitlements "$ENTITLEMENTS"
echo "signing: $MODE signed $(basename "$APP")"
