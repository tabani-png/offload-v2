# 0020. Device ingest protocol: signed batches, closed upload kinds, idempotent

Status: accepted, revised 2026-11-14 · Date: 2026-11-14 · Adapts old ADR 0103

## Context
The Mac uploads masked observations and, from M6, the results of device commands. The server must accept only known
shapes, from known devices, exactly once, and the Swift and TypeScript sides must agree on every byte.

## Decision
- **Upload kinds are a closed set**: `observation_batch`, `review_event`, `notice_ack`, `keyframe`, `step_result`. Any
  other kind is rejected with `unknown_kind`. A kind valid in the contract but not yet live rejects each of its objects
  with `not_enabled` (non-retryable): `review_event` until M4, `notice_ack` until M9, `step_result` until M6.
  `keyframe` is uploaded only through `POST /v1/ingest/keyframes` (on `/batches` it is `400 unknown_kind`) and only
  when the member has `keyframes_to_cloud` on.
- **Envelope**: `IngestEnvelope { v: 1, device_id (uuid), seq, sent_at, kind, objects[] }`, serialized with RFC 8785
  JCS, at most 500 objects and 1 MiB (keyframe uploads: one image per request, at most 512 KiB, JPEG). The object
  schema is selected by `envelope.kind` ([API.md](../API.md#3-device-ingest)).
- **Auth**: `Authorization: Bearer <device token>` (audience `device`, [ADR 0014](0014-identity.md)) and
  `Offload-Signature: keyid=<device_id>, sig=<base64url>`. The signature is ECDSA P-256/SHA-256 as the 64-byte raw
  `r‖s`, base64url without padding, over the exact request body, which must equal `jcs(JSON.parse(body))`
  (else `400 invalid_request`).
- **Order of checks** (each failure stops the request unless marked per object; [API.md](../API.md#3-device-ingest)
  has the same list):
  1. device token valid (else 401); rate limit 60 requests per minute per device (else `429 rate_limited`);
  2. body at most 1 MiB (else `413 too_large`), equal to its JCS (else `400 invalid_request`), signature verifies with
     the device's registered key (else 401, nothing stored);
  3. `envelope.device_id` and `keyid` equal the token's `device_id` claim (else `403 forbidden`);
  4. look up `ingest_batches(device_id, seq)`: same `body_sha256` → return the stored receipt; different bytes →
     `409 seq_replay`; otherwise require `seq > devices.last_seq` (else `409 seq_replay`);
  5. `sent_at` within ±10 minutes of server time (else `400 clock_skew`, whole batch, nothing stored);
  6. envelope kind (`400 unknown_kind`; kinds not yet enabled reject every object `not_enabled`);
  7. per object: schema (`schema_invalid`; a `ts` more than 10 minutes in the future is `schema_invalid`), age
     (`too_old` when `ts` is older than 7 days, except imported objects, below), upload consent for observations
     (`consent_missing`), leak scan (`leak_detected`, audited as `privacy.leak_blocked` with object id and detector
     name only), exclusion match (`excluded`);
  8. insert accepted objects idempotently on `(tenant_id, device_id, object_id, day)`; insert the `ingest_batches` row
     with `body_sha256` and update `devices.last_seq`; write `observations.ingested` to the outbox; all in one
     transaction; return the receipt.
- **Imported objects** (recordings import, M3 task m3-05): objects with `source = "import"` and the `import_id` of an
  open import owned by the member skip the `too_old` check. Their `day` is the UTC date of ingest, not of `ts`, so the
  raw and text TTLs count from the import and the import space is also wiped as a unit; analysis uses `ts`.
- **Receipt**: `IngestReceipt { accepted: [id], rejected: [{ id, code }] }`. Only `rate_limited` and `server_error`
  are retryable. Rate limit: 60 requests per minute per device.
- **Client behaviour**: the uploader persists each batch's exact bytes and `seq` before sending; after a crash it
  resends identical bytes. Flush every 5 minutes and on app quit; exponential backoff up to 6 hours; objects older than
  7 days are dropped locally with a counter shown in the UI. On `409 seq_replay` it re-reads the receipt with the same
  bytes; if its own bytes differ (a client bug) it re-batches under a new `seq` and counts it. Every sent batch is
  written to the local egress ledger ([ADR 0035](0035-mac-egress-guard-and-ledger.md)).
- TLS 1.2+ (prefer 1.3), HSTS. No extra payload encryption layer.

## Consequences
- The old `run_outcome`, `baseline_sample` and `daily_aggregate` kinds are gone: runs and baselines are computed in the
  cloud.
- Swift and TypeScript share the JCS vectors and signature fixtures ([ADR 0008](0008-contracts-first.md)).

## Alternatives considered
- Streaming (WebSocket): more state, no benefit for 5-minute batches.
- DER-encoded signatures: Swift and JOSE disagree by default; raw `r‖s` is unambiguous.

## Sources
Old ADR 0103, 0111; old `brain/src/sync/*`.

## Revisions
- 2026-11-14: `step_result` kind (review-c P0-1); signature encoding and signed bytes (review-a #4); check order with
  `body_sha256` lookup (review-a #21, #22); `clock_skew` (review-a #23); device id equality (review-a #24); `too_old`
  and future `ts` (review-a #20); `not_enabled` (review-a #6); keyframes only on their route; rate limit
  (review-a #117); restart resend rule (review-a #43, #44).
- 2026-11-14 (final pass): check order aligned with API.md (rate limit with the token, size and JCS before the signature, device id before seq); upload consent check (`consent_missing`); imported objects skip `too_old` and use the ingest date as `day` (final pass, W2 handoff).
