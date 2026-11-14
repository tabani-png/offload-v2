# 0020. Device ingest protocol: signed batches, closed upload kinds, idempotent

Status: accepted · Date: 2026-11-14 · Adapts old ADR 0103

## Context
The Mac uploads masked observations. The server must accept only known shapes, from known devices, exactly once.

## Decision
- **Upload kinds are a closed set**: `observation_batch`, `review_event`, `notice_ack`, `keyframe`. Any other kind is
  rejected with `unknown_kind`. `keyframe` is accepted only when the tenant member has `keyframes_to_cloud` on.
- **Envelope**: `IngestEnvelope { v: 1, device_id, seq, sent_at, kind, objects[] }`, serialized with RFC 8785 JCS,
  at most 500 objects and 1 MiB (keyframe uploads: one image per request, at most 512 KiB, JPEG).
- **Auth**: `Authorization: Bearer <device token>` ([ADR 0014](0014-identity.md)) and
  `Offload-Signature: keyid=<device_id>, sig=<base64url ES256 over the JCS bytes>`.
- **Replay and idempotency**: `seq` strictly increases per device; `sent_at` within ±10 minutes of server time;
  object ids are ULIDs; ingest is idempotent on `(tenant_id, device_id, object_id)`. A repeated batch returns the same
  receipt.
- **Receipt**: `IngestReceipt { accepted: [id], rejected: [{ id, code }] }`. Only `rate_limited` and `server_error`
  are retryable.
- **Server-side checks** before storing: schema validation, leak scan (`packages/masking`), exclusion check (the server
  also holds the member's exclusion list and drops anything that matches), size limits.
- **Client behaviour**: flush every 5 minutes and on app quit; exponential backoff up to 6 hours; objects older than 7
  days are dropped locally with a counter shown in the UI.
- TLS 1.2+ (prefer 1.3), HSTS. No extra payload encryption layer.

## Consequences
- The old `run_outcome`, `baseline_sample` and `daily_aggregate` kinds are gone: runs and baselines are now computed in
  the cloud.

## Alternatives considered
- Streaming (WebSocket): more state, no benefit for 5-minute batches.

## Sources
Old ADR 0103, 0111; old `brain/src/sync/*`.
