#!/usr/bin/env bash
# bundle.sh <release|dev>: assembles Offload.app from the `swift build -c release` product (DEPLOYMENT 3.1, 3.2).
#   Offload.app/Contents/{Info.plist, MacOS/Offload, Frameworks/Sparkle.framework, Resources/THIRD_PARTY_NOTICES.txt}
# Inputs (environment, all optional):
#   BUILD_DIR              default apps/mac/.build/release
#   OUT_DIR                default apps/mac/.build/bundle (Offload.app is written inside it, replacing an old one)
#   OFFLOAD_VERSION        MAJOR.MINOR.PATCH from the tag, default 0.0.0
#   OFFLOAD_BUILD_NUMBER   the CI run number (only increases; Sparkle compares it), default 1
#   OFFLOAD_DOWNLOADS_HOST public repository variable; the appcast host (operator item O13)
#   SPARKLE_ED_PUBLIC_KEY  public repository variable; Sparkle's EdDSA public key (operator item O11)
#   NOTICE_FILE            default the repository NOTICE, copied to Resources/THIRD_PARTY_NOTICES.txt
# Without the downloads host or the public key the four feed keys are left out and the app reports
# "updates off in this build". Bash 3.2. Never set -x.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
MAC="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$MAC/../.." && pwd)"

case "${1:-}" in
  release) BUNDLE_ID="ai.offload.mac" ;;      # OQ-16 default until operator item O2 locks it
  dev) BUNDLE_ID="ai.offload.mac.dev" ;;
  *) echo "usage: bundle.sh <release|dev>" >&2; exit 2 ;;
esac
FLAVOUR="$1"

BUILD_DIR="${BUILD_DIR:-$MAC/.build/release}"
OUT_DIR="${OUT_DIR:-$MAC/.build/bundle}"
VERSION="${OFFLOAD_VERSION:-0.0.0}"
BUILD_NUMBER="${OFFLOAD_BUILD_NUMBER:-1}"
HOST="${OFFLOAD_DOWNLOADS_HOST:-}"
ED_KEY="${SPARKLE_ED_PUBLIC_KEY:-}"
NOTICE_FILE="${NOTICE_FILE:-$ROOT/NOTICE}"

# Everything below is written into XML, so every value is checked against a strict pattern first.
echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "bundle: version must be MAJOR.MINOR.PATCH" >&2; exit 1; }
echo "$BUILD_NUMBER" | grep -Eq '^[1-9][0-9]{0,8}$' || { echo "bundle: build number must be a positive integer" >&2; exit 1; }
if [ -n "$HOST" ]; then
  echo "$HOST" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$' \
    || { echo "bundle: OFFLOAD_DOWNLOADS_HOST must be a bare host name" >&2; exit 1; }
fi
if [ -n "$ED_KEY" ]; then
  echo "$ED_KEY" | grep -Eq '^[A-Za-z0-9+/]{43}=$' \
    || { echo "bundle: SPARKLE_ED_PUBLIC_KEY must be a base64 Ed25519 public key" >&2; exit 1; }
fi

[ -f "$BUILD_DIR/Offload" ] || { echo "bundle: $BUILD_DIR/Offload not found (run swift build -c release)" >&2; exit 1; }
[ -d "$BUILD_DIR/Sparkle.framework" ] || { echo "bundle: $BUILD_DIR/Sparkle.framework not found" >&2; exit 1; }
[ -f "$NOTICE_FILE" ] || { echo "bundle: notices file not found" >&2; exit 1; }

APP="$OUT_DIR/Offload.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BUILD_DIR/Offload" "$APP/Contents/MacOS/Offload"
chmod 755 "$APP/Contents/MacOS/Offload"
cp -RP "$BUILD_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp "$NOTICE_FILE" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.txt"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ -n "$HOST" ] && [ -n "$ED_KEY" ]; then
  FEED=1
  feed_line="updates: feed https://$HOST/appcast.xml"
else
  FEED=0
  feed_line="updates off in this build (absent: $(absent_names OFFLOAD_DOWNLOADS_HOST SPARKLE_ED_PUBLIC_KEY))"
fi
awk -v feed="$FEED" '
  /@@FEED_BEGIN@@/ { skip = (feed == 0); next }
  /@@FEED_END@@/ { skip = 0; next }
  !skip { print }
' "$HERE/Info.plist.template" \
  | sed -e "s/@@BUNDLE_ID@@/$BUNDLE_ID/" -e "s/@@VERSION@@/$VERSION/" -e "s/@@BUILD_NUMBER@@/$BUILD_NUMBER/" \
        -e "s/@@DOWNLOADS_HOST@@/$HOST/" -e "s#@@ED_PUBLIC_KEY@@#$ED_KEY#" \
  > "$APP/Contents/Info.plist"
if grep -q '@@' "$APP/Contents/Info.plist"; then echo "bundle: unfilled placeholder in Info.plist" >&2; exit 1; fi

echo "bundle: $APP ($FLAVOUR, $BUNDLE_ID $VERSION build $BUILD_NUMBER)"
echo "$feed_line"
