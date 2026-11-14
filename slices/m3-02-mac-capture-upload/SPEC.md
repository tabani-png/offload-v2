---
id: m1-05-mac-capture-upload
title: Mac observer, on-device masker, encrypted 7-day buffer, device enrollment client and signed uploader
milestone: M1
status: ready
depends_on: [m1-01-contracts-ingest, m1-03-device-enrollment, m1-04-ingest-batches]
parallel_safe: true
human_gated: true
verify: bash slices/m1-05-mac-capture-upload/verify.sh
min_tests: 16
paths_in_scope: [apps/mac/**, packages/contracts/scripts/gen-swift.ts, slices/m1-05-mac-capture-upload/**, NOTICE]
paths_out_of_scope: [ee/**, services/**, packages/db/**, apps/web/**, docs/adr/**]
red_tests: [NONET, MASK, EXCLUDE, STORE, UPLOAD]
---

# m1-05-mac-capture-upload

## Summary
The thin Mac client's capture half ([ARCHITECTURE section 1](../../docs/ARCHITECTURE.md#1-mac-client),
[ADR 0006](../../docs/adr/0006-metadata-first-capture.md), [ADR 0007](../../docs/adr/0007-cloud-brain-thin-mac-client.md)).
Ports the old engine's observer, detectors, exclusions and AES-GCM store ([MIGRATION.md](../../docs/MIGRATION.md#2-old-repo-parts))
into SwiftPM targets, and adds an uploader that the observer cannot reach. `human_gated: true` because the owner must
grant macOS permissions on a real Mac for the exit demo.

## Contract
- Targets in `apps/mac/Package.swift`: `OffloadObserver` (no networking imports), `OffloadStore`, `OffloadMasker`,
  `OffloadUploader`, `OffloadMac` (app). The observer depends on store and masker only.
- Cadence: tick 1 s; focus 2 s; idle 120 s; input counts 60 s; OCR on change or 30 s; text ≤ 8000 chars.
- Store: `days/YYYY-MM-DD.jsonl.enc`, AES-256-GCM, day key wrapped by Keychain master key (service `ai.offload.mac`,
  account `master-key`); 7-day purge hourly.
- Uploader: generated Swift types from `packages/contracts/schemas`; envelope per API.md section 3; P-256 key in the
  Keychain; device token refresh; flush every 300 s and on quit; backoff to 6 h; drops objects older than 7 days with a
  counter.
- Enrollment client: loopback HTTP listener on 127.0.0.1, random port, PKCE S256.
- Any code ported from farzaa/clicky (MIT) is listed in `NOTICE` in the same commit.

## Red tests
Folder: `apps/mac/Tests/OffloadMacTests/M105/` (Swift Testing, `@Test("TAG: ...")`).

| Tag | Test name | Asserts |
|---|---|---|
| NONET | NONET: observer sources contain no networking API | scans `OffloadObserver` sources for URLSession, Network, NWConnection, CFStream, socket(, URLRequest |
| NONET | NONET: observer target does not link the uploader | package graph check |
| MASK | MASK: card, IBAN, API key, email and URL query are masked before the day file is written | |
| MASK | MASK: person names in a signature block become person placeholders | |
| MASK | MASK: text over 8000 characters is truncated after masking | |
| MASK | MASK: unchanged text hash writes no new text_snapshot | |
| EXCLUDE | EXCLUDE: a password manager window yields the app name only | |
| EXCLUDE | EXCLUDE: a private browsing title marker drops title and host | |
| EXCLUDE | EXCLUDE: a user exclusion added at runtime applies within one 2 s reload | |
| STORE | STORE: a day file decrypts only with its day key | |
| STORE | STORE: purge removes days older than 7 and logs them | |
| STORE | STORE: secure input pauses text capture | |
| UPLOAD | UPLOAD: envelope bytes are JCS and the signature verifies with the public JWK | |
| UPLOAD | UPLOAD: offline queue flushes in seq order after reconnect | |
| UPLOAD | UPLOAD: a 409 seq_replay response does not resend the batch | |
| UPLOAD | UPLOAD: objects older than 7 days are dropped and counted | |

## Out of scope
Onboarding UI, Today, the local now summary (M2), keyframe upload, recordings import.

## Verify
`bash slices/m1-05-mac-capture-upload/verify.sh` (macOS only; CI `mac` job).

## Scope changes
None.
