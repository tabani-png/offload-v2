#!/usr/bin/env bash
# Builds the downloadable test build of Offload.app: release `swift build`, bundle, ad hoc signature, zip, and the
# installed-copy smoke check. Slice m3-09-mac-test-build; workflow .github/workflows/mac-artifact.yml.
# Bundle assembly and the checksum-verified pinned download are ported from the old repo's app/build.sh
# (docs/MIGRATION.md sections 5.1 and 5.2), without bun or the brain: the brain is in the cloud.
# Developer ID signing, notarization and Sparkle are m3-03 (apps/mac/Packaging); this folder folds into it later.
#
#   build-app.sh info-plist <version> <build> <commit>   print the test build's Info.plist
#   build-app.sh version                                 print apps/mac/TestBuild/VERSION
#   build-app.sh artifact-name <sha>                     print Offload-mac-<first 7>.zip
#   build-app.sh assemble <binary> <out-dir>             <out-dir>/Offload.app (OFFLOAD_BUILD_NUMBER, OFFLOAD_COMMIT)
#   build-app.sh sign <app>                              ad hoc signature
#   build-app.sh check <app>                             structure, Info.plist, ad hoc signature
#   build-app.sh smoke <app>                             copy, check, run --version with an empty environment
#   build-app.sh zip <app> <zip>                         ditto zip of the bundle
#   build-app.sh fetch-pinned <url> <sha256> <out>       download and verify against a pinned checksum
#   build-app.sh all <out-dir>                           macOS: build, assemble, sign, check, zip, copy the guide
#
# macOS tools come from CODESIGN, DITTO and CURL (defaults codesign, ditto, curl) so the tests can fake them.
# Bash 3.2 compatible. Never traces (no set -x): nothing secret is read here, and it stays that way.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MAC="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$MAC/../.." && pwd)"

BUNDLE_ID="ai.offload.mac.dev"   # ROADMAP O2: dev and test builds never take the release id ai.offload.mac
EXE_NAME="Offload"
MIN_MACOS="14.0"
CATEGORY="public.app-category.productivity"
# docs/DEPLOYMENT.md section 3.2
SCREEN_USAGE="Offload reads what's on screen, on this Mac, to understand your work."
SMOKE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
SMOKE_SECONDS=30
BUNDLE_MAX_MB="${BUNDLE_MAX_MB:-50}"   # DEPLOYMENT 3.1 planning figure
NOTICES="THIRD_PARTY_NOTICES.txt"     # the name m3-03's check-bundle.sh uses

CODESIGN="${CODESIGN:-codesign}"
DITTO="${DITTO:-ditto}"
CURL="${CURL:-curl}"

die() { echo "build-app.sh: $1" >&2; exit "${2:-1}"; }
usage() { die "usage: $1" 2; }

valid_version() { printf '%s' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; }
valid_build() { printf '%s' "$1" | grep -Eq '^[0-9]+$'; }
valid_sha() { printf '%s' "$1" | grep -Eq '^[0-9a-fA-F]{7,40}$'; }
short_sha() { printf '%s' "$1" | cut -c1-7 | tr 'A-F' 'a-f'; }

xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
kv() { printf '  <key>%s</key><string>%s</string>\n' "$1" "$(xml_escape "$2")"; }
kb() { printf '  <key>%s</key><%s/>\n' "$1" "$2"; }

info_plist() {
  [ $# -eq 3 ] || usage "info-plist <version> <build> <commit>"
  valid_version "$1" || die "version must be MAJOR.MINOR.PATCH, got '$1'" 2
  valid_build "$2" || die "build must be digits, got '$2'" 2
  valid_sha "$3" || die "commit must be 7 to 40 hex characters" 2
  cat <<'HEAD'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
HEAD
  kv CFBundleDevelopmentRegion en
  kv CFBundleExecutable "$EXE_NAME"
  kv CFBundleIdentifier "$BUNDLE_ID"
  kv CFBundleInfoDictionaryVersion "6.0"
  kv CFBundleName Offload
  kv CFBundleDisplayName Offload
  kv CFBundlePackageType APPL
  kv CFBundleShortVersionString "$1"
  kv CFBundleVersion "$2"
  kv LSMinimumSystemVersion "$MIN_MACOS"
  kb LSUIElement true
  kv LSApplicationCategoryType "$CATEGORY"
  kb NSHighResolutionCapable true
  kv NSPrincipalClass NSApplication
  kv NSScreenCaptureUsageDescription "$SCREEN_USAGE"
  kv OffloadCommit "$(short_sha "$3")"
  kv OffloadBuildKind test
  printf '</dict>\n</plist>\n'
}

read_version() {
  local v
  v="$(tr -d ' \t\r\n' < "$HERE/VERSION")"
  valid_version "$v" || die "apps/mac/TestBuild/VERSION must be MAJOR.MINOR.PATCH" 2
  printf '%s\n' "$v"
}

artifact_name() {
  [ $# -eq 1 ] || usage "artifact-name <sha>"
  valid_sha "$1" || die "not a commit sha" 2
  printf 'Offload-mac-%s.zip\n' "$(short_sha "$1")"
}

assemble() {
  [ $# -eq 2 ] || usage "assemble <binary> <out-dir>"
  local bin="$1" out="$2" app version build commit b
  [ -f "$bin" ] || die "no binary at $bin (run swift build -c release first)"
  # SwiftPM's generated Bundle.module looks for a resource bundle at the .app root and at the build machine's path,
  # never in Contents/Resources, and codesign refuses files at the .app root. Copying one into Resources would give
  # an app that crashes on first resource use on every Mac but the build runner, so stop instead (none exist today).
  for b in "$(dirname "$bin")"/*.bundle; do
    if [ -d "$b" ]; then
      die "SwiftPM resource bundle $(basename "$b") beside the binary: Bundle.module would not find it inside an installed Offload.app. Load it through Bundle.main.resourceURL first, then copy it here."
    fi
  done
  version="$(read_version)"
  build="${OFFLOAD_BUILD_NUMBER:-1}"
  commit="${OFFLOAD_COMMIT:-0000000}"
  app="$out/Offload.app"
  info_plist "$version" "$build" "$commit" >/dev/null   # validate before touching the output folder
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  info_plist "$version" "$build" "$commit" > "$app/Contents/Info.plist"
  printf 'APPL????' > "$app/Contents/PkgInfo"
  cp "$bin" "$app/Contents/MacOS/$EXE_NAME"
  chmod 755 "$app/Contents/MacOS/$EXE_NAME"
  # The executable links Sparkle (m3-03) and loads it from @executable_path/../Frameworks. -P keeps the framework's
  # version symlinks, as m3-03's bundle.sh does.
  if [ -d "$(dirname "$bin")/Sparkle.framework" ]; then
    mkdir -p "$app/Contents/Frameworks"
    cp -RP "$(dirname "$bin")/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
  fi
  # DEPLOYMENT 3.1: a third-party notices file in every bundle; the MIT license beside it.
  cp "$REPO/NOTICE" "$app/Contents/Resources/$NOTICES"
  cp "$REPO/LICENSE" "$app/Contents/Resources/LICENSE.txt"
  find "$app" -name .DS_Store -delete
  echo "assembled $app ($version, build $build, $(short_sha "$commit"))"
}

sign_adhoc() {
  [ $# -eq 1 ] || usage "sign <app>"
  [ -d "$1" ] || die "no bundle at $1"
  local fw="$1/Contents/Frameworks/Sparkle.framework"
  # Inside-out, never --deep, in m3-03's sign.sh order: Sparkle's XPC services removed (the app is not sandboxed),
  # its helpers, the framework, then the app. No hardened runtime: this is the ad hoc test build.
  if [ -d "$fw" ]; then
    rm -rf "$fw/Versions/B/XPCServices" "$fw/XPCServices"
    "$CODESIGN" --force --sign - --timestamp=none "$fw/Versions/B/Autoupdate"
    "$CODESIGN" --force --sign - --timestamp=none "$fw/Versions/B/Updater.app"
    "$CODESIGN" --force --sign - --timestamp=none "$fw"
  fi
  "$CODESIGN" --force --sign - --timestamp=none "$1"
  echo "signed ad hoc $1"
}

# Prints the value of a <string> key or true/false for a boolean key in a flat XML plist.
plist_get() {
  awk -v k="<key>$2</key>" '
    index($0, k) { found = 1 }
    found {
      if (match($0, /<string>[^<]*<\/string>/)) { s = substr($0, RSTART + 8, RLENGTH - 17); print s; exit }
      if ($0 ~ /<true\/>/) { print "true"; exit }
      if ($0 ~ /<false\/>/) { print "false"; exit }
    }' "$1"
}

check_app() {
  [ $# -eq 1 ] || usage "check <app>"
  local app="$1" plist exe fails=0 got want key
  plist="$app/Contents/Info.plist"
  exe="$app/Contents/MacOS/$EXE_NAME"
  f() { echo "FAIL $*"; fails=$((fails + 1)); }
  valid_build "$BUNDLE_MAX_MB" || die "BUNDLE_MAX_MB must be a whole number of MB" 2
  [ -d "$app" ] || { f "no bundle at $app"; return 1; }
  [ -f "$plist" ] || f "missing Contents/Info.plist"
  [ -f "$app/Contents/PkgInfo" ] || f "missing Contents/PkgInfo"
  [ -d "$app/Contents/Resources" ] || f "missing Contents/Resources"
  if [ -f "$exe" ]; then [ -x "$exe" ] || f "Contents/MacOS/$EXE_NAME is not executable"; else f "missing Contents/MacOS/$EXE_NAME"; fi
  if [ -f "$plist" ]; then
    if command -v plutil >/dev/null 2>&1; then plutil -lint -s "$plist" >/dev/null || f "Info.plist does not lint"; fi
    for pair in "CFBundleIdentifier=$BUNDLE_ID" "CFBundleExecutable=$EXE_NAME" "CFBundlePackageType=APPL" \
      "LSMinimumSystemVersion=$MIN_MACOS" "LSUIElement=true" "LSApplicationCategoryType=$CATEGORY" \
      "NSPrincipalClass=NSApplication" "OffloadBuildKind=test"; do
      key="${pair%%=*}"; want="${pair#*=}"
      got="$(plist_get "$plist" "$key")"
      [ "$got" = "$want" ] || f "Info.plist $key is '${got}', want '$want'"
    done
    [ -n "$(plist_get "$plist" NSScreenCaptureUsageDescription)" ] || f "Info.plist NSScreenCaptureUsageDescription is missing"
    valid_version "$(plist_get "$plist" CFBundleShortVersionString)" || f "Info.plist CFBundleShortVersionString is not MAJOR.MINOR.PATCH"
    valid_build "$(plist_get "$plist" CFBundleVersion)" || f "Info.plist CFBundleVersion is not a number"
    valid_sha "$(plist_get "$plist" OffloadCommit)" || f "Info.plist OffloadCommit is not a commit"
  fi
  # DEPLOYMENT 3.1 bundle rules: notices present, no Mach-O under Resources, size budget.
  [ -s "$app/Contents/Resources/$NOTICES" ] || f "missing Contents/Resources/$NOTICES"
  if [ -d "$app/Contents/Resources" ]; then
    while IFS= read -r r; do
      [ -n "$r" ] || continue
      case "$(od -An -tx1 -N4 "$r" 2>/dev/null | tr -d ' \n')" in
        feedface|cefaedfe|feedfacf|cffaedfe|cafebabe|bebafeca) f "Mach-O under Resources: ${r#"$app"/}" ;;
      esac
    done <<EOF_FIND
$(find "$app/Contents/Resources" -type f 2>/dev/null)
EOF_FIND
  fi
  local kb; kb="$(du -sk "$app" | cut -f1)"
  [ "$kb" -le $((BUNDLE_MAX_MB * 1024)) ] || f "bundle is ${kb} KB, over the size budget of ${BUNDLE_MAX_MB} MB"
  "$CODESIGN" --verify --deep --strict "$app" >/dev/null 2>&1 || f "codesign --verify --deep --strict rejects the bundle"
  "$CODESIGN" -dv --verbose=2 "$app" 2>&1 | grep -q '^Signature=adhoc' || f "the signature is not ad hoc"
  [ "$fails" -eq 0 ] || return 1
  echo "check ok: $app"
}

# Runs "$@" with a time limit (no coreutils timeout on macOS). Output goes to the caller's redirection.
run_limited() {
  local secs="$1"; shift
  "$@" &
  local pid=$! n=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$n" -ge $((secs * 10)) ]; then kill -9 "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; return 124; fi
    sleep 0.1; n=$((n + 1))
  done
  wait "$pid"
}

smoke() {
  [ $# -eq 1 ] || usage "smoke <app>"
  [ -d "$1" ] || die "no bundle at $1"
  local t rc=0
  t="$(mktemp -d "${TMPDIR:-/tmp}/offload-smoke.XXXXXX")"
  smoke_in "$1" "$t" || rc=$?
  rm -rf "$t"
  return "$rc"
}

smoke_in() {
  local app="$1" t="$2" copy plist want out code=0
  mkdir -p "$t/home"
  copy="$t/Applications/Offload.app"
  mkdir -p "$t/Applications"
  "$DITTO" "$app" "$copy"
  echo "installed copy: $copy"
  check_app "$copy" || { echo "FAIL the installed copy does not pass check"; return 1; }
  plist="$copy/Contents/Info.plist"
  want="Offload $(plist_get "$plist" CFBundleShortVersionString) ($(plist_get "$plist" CFBundleVersion)) $(plist_get "$plist" OffloadCommit) $BUNDLE_ID"
  out="$(cd "$t" && run_limited "$SMOKE_SECONDS" env -i HOME="$t/home" PATH="$SMOKE_PATH" TMPDIR="$t" \
    "$copy/Contents/MacOS/$EXE_NAME" --version 2>&1)" || code=$?
  echo "--version: $out"
  [ "$code" -eq 0 ] || { echo "FAIL --version exited $code"; return 1; }
  [ "$out" = "$want" ] || { echo "FAIL --version printed '$out', want '$want'"; return 1; }
  echo "smoke ok"
}

zip_app() {
  [ $# -eq 2 ] || usage "zip <app> <zip>"
  rm -f "$2"
  "$DITTO" -c -k --sequesterRsrc --keepParent "$1" "$2"
  echo "zipped $2"
}

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1; else sha256sum "$1" | cut -d' ' -f1; fi
}

# The old app/build.sh pattern (bun from its release, checked against SHASUMS256.txt), as a general step for any
# pinned tool. Nothing in this build downloads; m3-03's Sparkle tools can use it.
fetch_pinned() {
  [ $# -eq 3 ] || usage "fetch-pinned <url> <sha256> <out>"
  local url="$1" want out="$3" got
  want="$(printf '%s' "$2" | tr 'A-F' 'a-f')"
  printf '%s' "$want" | grep -Eq '^[0-9a-f]{64}$' || die "the pinned checksum must be 64 hex characters" 2
  mkdir -p "$(dirname "$out")"
  rm -f "$out"
  "$CURL" -fsSL --retry 3 -o "$out.part" "$url" || { rm -f "$out.part"; die "could not download $url"; }
  got="$(sha256_of "$out.part")"
  if [ "$got" != "$want" ]; then
    rm -f "$out.part"
    die "checksum mismatch for $url (want $want, got $got)"
  fi
  mv "$out.part" "$out"
  echo "fetched $out (sha256 ok)"
}

all() {
  [ $# -eq 1 ] || usage "all <out-dir>"
  [ "$(uname -s)" = "Darwin" ] || die "all needs macOS (swift build, codesign, ditto)"
  local out="$1" binpath name
  mkdir -p "$out"
  out="$(cd "$out" && pwd)"
  (cd "$MAC" && swift build -c release --product "$EXE_NAME")
  binpath="$(cd "$MAC" && swift build -c release --show-bin-path)"
  assemble "$binpath/$EXE_NAME" "$out"
  sign_adhoc "$out/Offload.app"
  check_app "$out/Offload.app"
  name="$(artifact_name "${OFFLOAD_COMMIT:-0000000}")"
  zip_app "$out/Offload.app" "$out/$name"
  cp "$HERE/INSTALL_AND_TEST.md" "$out/INSTALL_AND_TEST.md"
  ls -l "$out"
}

cmd="${1:-}"
[ $# -gt 0 ] && shift
case "$cmd" in
  info-plist) info_plist "$@" ;;
  version) read_version ;;
  artifact-name) artifact_name "$@" ;;
  assemble) assemble "$@" ;;
  sign) sign_adhoc "$@" ;;
  check) check_app "$@" ;;
  smoke) smoke "$@" ;;
  zip) zip_app "$@" ;;
  fetch-pinned) fetch_pinned "$@" ;;
  all) all "$@" ;;
  *) usage "build-app.sh info-plist|version|artifact-name|assemble|sign|check|smoke|zip|fetch-pinned|all ..." ;;
esac
