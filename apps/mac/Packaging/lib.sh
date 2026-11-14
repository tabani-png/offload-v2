# Shared helpers for the packaging scripts. Bash 3.2. Sourced, never run. Never prints a value from the environment.
PATH="${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}"
export PATH

# absent_names NAME...: prints the names whose variable is unset or empty (a presence check; values are never read
# into output).
absent_names() {
  local n out=""
  for n in "$@"; do
    if [ -z "${!n:-}" ]; then out="$out $n"; fi
  done
  printf '%s' "${out# }"
}

# The OS the scripts act as. PACKAGING_OS exists so tests on a Mac can exercise the non-macOS refusals.
packaging_os() { printf '%s' "${PACKAGING_OS:-$(uname -s)}"; }

# sha256_of FILE: hex digest with whichever tool the host has (shasum on macOS, sha256sum on Linux).
sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else sha256sum "$1" | cut -d' ' -f1; fi
}

# find_identity KEYCHAIN: the SHA-1 of the Developer ID Application identity in the keychain (not a secret).
find_identity() {
  security find-identity -v -p codesigning "$1" | sed -n 's/^ *[0-9][0-9]*) \([0-9A-F]\{40\}\) "Developer ID Application: .*/\1/p' | head -1
}

# Where sign.sh leaves the temporary keychain; release-mac.yml deletes it in a step that always runs.
signing_keychain() { printf '%s' "${OFFLOAD_SIGNING_KEYCHAIN:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/offload-signing.keychain-db}"; }
