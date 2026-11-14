---
id: m3-02-mac-capture-upload
title: Mac Accessibility-first observer, on-device masker with stable keyed pseudonyms, encrypted 7-day buffer, enrollment client, and the uploader as egress guard with a local egress ledger
milestone: M3
status: ready
depends_on: [m1-02-contracts-ingest, m1-04-login-devices, m3-01-ingest-batches]
parallel_safe: false
human_gated: true
model_tier: sonnet
size: L
parallel_group: M3-B
owns: [apps/mac/**, .github/workflows/ci.yml]
verify: bash slices/m3-02-mac-capture-upload/verify.sh
min_tests: 30
paths_in_scope: [apps/mac/**, packages/contracts/scripts/gen-swift.ts, packages/contracts/package.json, packages/contracts/tests/fixtures/**, slices/m3-02-mac-capture-upload/**, .github/workflows/ci.yml, package.json, bun.lock]
paths_out_of_scope: [ee/**, services/**, packages/db/**, packages/contracts/src/**, apps/web/**, docs/adr/**]
red_tests: [NONET, MASK, PSEUDO, EXCLUDE, STORE, UPLOAD, EGRESS]
---

# m3-02-mac-capture-upload

## Summary
The thin Mac client's capture half for [M3](../../docs/ROADMAP.md#m3-capture-to-cloud)
([ARCHITECTURE section 1](../../docs/ARCHITECTURE.md#1-mac-client), [ADR 0006](../../docs/adr/0006-metadata-first-capture.md),
[ADR 0007](../../docs/adr/0007-cloud-brain-thin-mac-client.md), [ADR 0028](../../docs/adr/0028-stable-keyed-pseudonyms.md),
[ADR 0035](../../docs/adr/0035-mac-egress-guard-and-ledger.md)). Ports the old engine's observer, detectors,
exclusions and AES-GCM store ([MIGRATION.md](../../docs/MIGRATION.md)) into the SwiftPM targets, makes Accessibility
the primary text source, adds pseudonyms, and adds an uploader the observer cannot reach. `human_gated: true`: the
owner grants macOS permissions on a real Mac with the bundled, signed app (operator items O1 to O3) for the exit demo.

## Contract
- Delete `apps/mac/Tests/OffloadMacTests/SmokeTests.swift` (the TODO markers are replaced).
- Targets (already declared in `apps/mac/Package.swift`): `OffloadContracts` (generated types + `JCS.swift`),
  `OffloadStore`, `OffloadMasker`, `OffloadObserver` (depends on Contracts, Store, Masker only; no networking),
  `OffloadUploader`, `OffloadMac` (app). `OffloadImport` and `OffloadActuator` stay markers in this slice.
- **Generated types**: `bun packages/contracts/scripts/gen-swift.ts` is a dependency-free emitter (no quicktype) that
  reads `packages/contracts/schemas/*.schema.json` and writes `apps/mac/Sources/OffloadContracts/Generated/*.swift`
  (Codable structs, closed enums, `additionalProperties: false` → decoding fails on unknown keys). Committed.
- **JCS**: `OffloadContracts/JCS.swift` (RFC 8785), tested against the shared vectors in
  `packages/contracts/tests/fixtures/jcs/` (copied into the test bundle as a resource by the test target).
- **Capture** (observer runs as a child of the app process for TCC attribution, spike S1):
  tick 1 s; focus on `NSWorkspace` activation plus a 2 s poll for title and URL; idle after 120 s
  (`CGEventSource`, no permission); **text**: bounded Accessibility walk of the focused window (at most 1,500 nodes,
  depth 12, 150 ms), on focus change and at most every 30 s when the text hash changed, secure text fields skipped;
  OCR (ScreenCaptureKit single window + Vision) only when the AX text has fewer than 200 characters, at most once per
  30 s per window, never on battery below 20%; text ≤ 8000 chars after masking, `text_source` `ax` or `ocr`;
  input counts are off by default (Input Monitoring is not requested at setup); pause on screen lock and sleep
  (`pause`/`resume` with `reason`); permission state checked every 5 s, a change emits `permission_change`.
- **Masker**: structured secrets masked destructively before write (cards with Luhn, CVV/expiry, SSN, SIN, bank
  routing and account, IBAN, CUSIP, ISIN, OTP codes, API keys and tokens, private keys). People, emails, phones and URL
  paths become **pseudonyms**: `HMAC-SHA256(tenant pseudonym key, normalised value)`, first 16 hex, shape
  `<person|email|phone|doc:h_…>`. Normalisation: NFKC + trim; email and doc lowercase; phone to E.164 digits; person =
  lowercased "first last". URLs keep the host; the path becomes `doc`; query and fragment are dropped. The tenant key
  (32 random bytes) is created at first enrollment and stored in the Keychain (this device only); a recovery code is
  shown once; the wrapped key is uploaded with `PUT /v1/devices/{id}/pseudonym-key-wrap`. A local reveal map
  (pseudonym → value) is kept in the encrypted store for 7 days and never uploaded.
- **Exclusions**: `exclusions.builtin.json` (same file as `packages/masking/src/exclusions.builtin.json`) plus user
  "Never watch" entries, reloaded every 2 s; match rules as in m3-01; an excluded window yields the app name only.
- **Store**: `days/YYYY-MM-DD.jsonl.enc`, AES-256-GCM, day key wrapped by the Keychain master key (service =
  the bundle id: `ai.offload.mac`, or `ai.offload.mac.dev` for dev builds; account `master-key`; after-first-unlock-this-device-only); 7-day purge hourly.
- **Uploader = egress guard**: one destination (the configured API host; any other host refused), payloads built only
  from the generated types (unknown keys impossible), the device detectors run again on every outgoing object, any
  error → nothing sent (fail closed). Envelope per [API.md section 3](../../docs/API.md#3-device-ingest), signed with
  the device key (Secure Enclave when available) as raw r‖s base64url. `seq` and each pending batch's exact bytes are
  persisted in the store **before** send; a restart resends identical bytes and seq. Flush every 300 s and on quit;
  backoff to 6 h; objects older than 7 days are dropped with a counter. On 409 `seq_replay` with identical bytes the
  stored receipt is re-read; if the bytes differ (client bug) the objects are re-batched under a new seq and a counter
  is logged. Device token refresh via the challenge path.
- **Local egress ledger**: every sent batch appends one sealed line (time, destination, kind, object count, bytes,
  counts by detector, and the exact bytes sent) to `egress/YYYY-MM-DD.jsonl.enc`; kept 7 days; readable in the app
  ("What was sent").
- **Enrollment client**: loopback HTTP listener on 127.0.0.1, random port, PKCE S256, `GET /v1/devices/authorize` in the
  system browser, then `POST /v1/devices/enroll`.
- Every slice test lives in `@Suite struct M302` under `apps/mac/Tests/OffloadMacTests/M302/`.

## Red tests
Folder: `apps/mac/Tests/OffloadMacTests/M302/` (Swift Testing, `@Test("TAG: ...")` inside `@Suite struct M302`).

| Tag | Test name | Asserts |
|---|---|---|
| NONET | NONET: observer sources contain no networking API | regex over `Sources/OffloadObserver`: `URLSession\|import Network\|NSURLConnection\|CFNetwork\|NWConnection\|CFStream\|socket\(\|URLRequest` |
| NONET | NONET: observer target does not link the uploader | package graph check |
| MASK | MASK: card, IBAN, API key and URL query are masked before the day file is written | |
| MASK | MASK: text over 8000 characters is truncated after masking | |
| MASK | MASK: unchanged text hash writes no new text_snapshot | |
| MASK | MASK: Accessibility text is used and OCR runs only under 200 characters | fake AX tree and fake OCR counter |
| MASK | MASK: the AX walk stops at 1,500 nodes, depth 12 or 150 ms | |
| PSEUDO | PSEUDO: the same email on two days gets the same pseudonym | |
| PSEUDO | PSEUDO: two tenants' keys give different pseudonyms for the same value | |
| PSEUDO | PSEUDO: a URL keeps its host, its path becomes a doc pseudonym and the query is dropped | |
| PSEUDO | PSEUDO: a person name in a signature block becomes a person pseudonym | |
| PSEUDO | PSEUDO: the reveal map resolves a pseudonym on the device and is purged after 7 days | |
| EXCLUDE | EXCLUDE: a password manager window yields the app name only | |
| EXCLUDE | EXCLUDE: a private browsing title marker drops title and host | |
| EXCLUDE | EXCLUDE: a user exclusion added at runtime applies within one 2 s reload | |
| STORE | STORE: a day file decrypts only with its day key | |
| STORE | STORE: purge removes days older than 7 and logs them | |
| STORE | STORE: secure input pauses text capture | |
| STORE | STORE: screen lock writes pause with reason lock and nothing until resume | |
| STORE | STORE: a lost Screen Recording grant writes permission_change and AX capture continues | |
| UPLOAD | UPLOAD: generated Swift types are fresh | re-run `gen-swift.ts`, byte-compare |
| UPLOAD | UPLOAD: JCS matches the shared RFC 8785 vectors | same folder as m1-02 |
| UPLOAD | UPLOAD: envelope bytes are JCS and the raw r‖s signature verifies with the public JWK | |
| UPLOAD | UPLOAD: offline queue flushes in seq order after reconnect | |
| UPLOAD | UPLOAD: kill after send before receipt, restart resends identical bytes and seq | |
| UPLOAD | UPLOAD: a 409 seq_replay with identical bytes re-reads the receipt and does not lose objects | |
| UPLOAD | UPLOAD: objects older than 7 days are dropped and counted | |
| EGRESS | EGRESS: a request to any host other than the configured API host is refused | |
| EGRESS | EGRESS: a detector hit at send time stops the batch and nothing leaves | fail closed |
| EGRESS | EGRESS: every sent batch appears in the local egress ledger with the exact bytes | purged after 7 days |

## Out of scope
Onboarding UI and the local "last 10 minutes" line (M3 follow-up slice, which also carries the Clicky permission-polling
port), Today, keyframe upload, recordings import (`OffloadImport`), the actuator (M6), on-device model pass evaluation.

## Verify
`bash slices/m3-02-mac-capture-upload/verify.sh`. On Linux it prints `m3-02-mac-capture-upload: SKIPPED (needs macOS)`
and exits 0; with `REQUIRE_MAC=1` (CI `mac` job) a skip fails.

## Scope changes
None.
