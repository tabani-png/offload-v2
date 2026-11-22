#!/usr/bin/env bash
# fetch-sparkle-tools.sh <dest>: downloads Sparkle's release archive (bin/sign_update, bin/generate_appcast) for the
# pinned version and verifies it against the SHA-256 digest GitHub publishes for the release asset before anything
# is extracted (the pinned, checksum-verified tool download of MIGRATION 5.1, written fresh). Prints the bin folder.
# SPARKLE_TOOLS_URL may point at a mirror of the same archive; the digest is pinned here and cannot be overridden.
# Keep SPARKLE_VERSION equal to the exact version in apps/mac/Package.swift. Bash 3.2.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
SPARKLE_VERSION="2.10.1"
SPARKLE_TOOLS_SHA256="1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27"
URL="${SPARKLE_TOOLS_URL:-https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz}"
DEST="${1:-}"
[ -n "$DEST" ] || { echo "usage: fetch-sparkle-tools.sh <dest>" >&2; exit 2; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
curl --fail --silent --show-error --location --proto '=https,file' --output "$work/sparkle.tar.xz" "$URL"
got="$(sha256_of "$work/sparkle.tar.xz")"
if [ "$got" != "$SPARKLE_TOOLS_SHA256" ]; then
  echo "sparkle tools: checksum mismatch for Sparkle $SPARKLE_VERSION (got $got); not used" >&2
  exit 1
fi
mkdir -p "$DEST"
tar -xJf "$work/sparkle.tar.xz" -C "$DEST"
[ -x "$DEST/bin/sign_update" ] && [ -x "$DEST/bin/generate_appcast" ] \
  || { echo "sparkle tools: archive has no bin/sign_update or bin/generate_appcast" >&2; exit 1; }
printf '%s\n' "$DEST/bin"
