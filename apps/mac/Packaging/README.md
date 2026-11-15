# apps/mac/Packaging

Turns the `swift build -c release` product into the signed, notarized, self-updating `Offload.app`
([DEPLOYMENT sections 3, 4, 6 and 13](../../../docs/DEPLOYMENT.md#3-signing-notarization-and-the-disk-image)).
Bash 3.2, `set -euo pipefail`, never `set -x`. Slice: [m3-03](../../../slices/m3-03-mac-signing-sparkle/SPEC.md).

| Script | What it does | Needs |
|---|---|---|
| `bundle.sh <release\|dev>` | `Offload.app` with `Info.plist` from `Info.plist.template`; bundle id `ai.offload.mac` or `ai.offload.mac.dev` | `OFFLOAD_VERSION`, `OFFLOAD_BUILD_NUMBER`; feed keys only with `OFFLOAD_DOWNLOADS_HOST` and `SPARKLE_ED_PUBLIC_KEY` (else "updates off in this build") |
| `check-bundle.sh <app>` | No Mach-O under `Resources/`, every executable passes `codesign --verify --strict`, notices file, size within `BUNDLE_MAX_MB` (50) | `codesign` (or `CODESIGN`) |
| `sign.sh <app> <adhoc\|developer-id>` | Removes Sparkle's XPC services, signs Autoupdate, Updater.app, Sparkle.framework, then the app; hardened runtime and timestamp; never `--deep` | developer-id: `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`, optional `APPLE_TEAM_ID`; macOS |
| `notarize.sh <app> <version>` | Notarize and staple the app, then the signed, notarized, stapled `Offload-<version>.dmg` | `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`; the keychain from `sign.sh`; macOS |
| `appcast.sh <zip> <version> <beta\|stable>` | `sign_update` and `generate_appcast` (deltas from the archives in the zip's folder) | `SPARKLE_ED_PRIVATE_KEY`, `OFFLOAD_DOWNLOADS_HOST`; macOS |
| `promote.sh <appcast> <promote\|halt> <version>` | `appcast-edit.ts`, then signs the feed again | `SPARKLE_ED_PRIVATE_KEY`; macOS |
| `fetch-sparkle-tools.sh <dest>` | Sparkle 2.10.1 release archive, refused unless its SHA-256 matches the pin | network |

A script whose secrets are absent prints `<step>: skipped (absent: <names>)` and exits 0. Secret values are never
printed; keys reach Sparkle's tools on stdin, the App Store Connect key goes to a 0600 temp file removed in a trap.
The one exception to "never on a command line" is the p12 password for `security import`, which has no other input.

Local use on a Mac (no secrets needed):

```
cd apps/mac && swift build -c release && cd ../..
bash apps/mac/Packaging/bundle.sh dev
bash apps/mac/Packaging/sign.sh apps/mac/.build/bundle/Offload.app adhoc
bash apps/mac/Packaging/check-bundle.sh apps/mac/.build/bundle/Offload.app
apps/mac/.build/bundle/Offload.app/Contents/MacOS/Offload --self-check
```

Ad hoc signatures lose permission grants on every rebuild (DEPLOYMENT section 2); daily use on the owner's Mac needs
the Apple Development identity of DEPLOYMENT 3.6. Keep `SPARKLE_VERSION` in `fetch-sparkle-tools.sh` equal to the
exact Sparkle version in `../Package.swift`.
