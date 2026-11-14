# 0005. Masked text only reaches models

Status: accepted, revised 2026-11-14 · Date: 2026-11-14 · Carries over old ADR 0007, 0010

## Context
The owner decided on 2026-11-14 that masked screen text may go to the cloud
([OQ-28](../OPEN_QUESTIONS.md#oq-28-masked-screen-text-to-the-cloud)); this ADR is how it stays masked on the way.
Model providers are third parties. Screen text holds names, emails, secrets and numbers. The cloud brain also needs to
know that two observations mention the same person, the same sheet or the same customer, or it cannot find tasks and
design fixes (review-c P0-4).

## Decision
- Masking happens twice:
  1. **On the Mac** before anything is stored in the upload buffer or uploaded:
     - **Structured secrets are destroyed**: card numbers, CVV/expiry, SSN/SIN, bank routing and account numbers, IBAN,
       CUSIP/ISIN, OTPs, API keys and secret-shaped tokens. They become fixed tokens (for example `<card>`) with no
       way back.
     - **People, emails, phone numbers and URL paths or document ids become stable keyed pseudonyms**
       ([ADR 0028](0028-stable-keyed-pseudonyms.md)): `<person:h_…>`, `<email:h_…>`, `<phone:h_…>`, `<doc:h_…>`.
       Equality survives; the value does not leave. URL hosts are kept; query strings and fragments are dropped.
     - Excluded windows produce no text at all.
  2. **In the model router** (the single egress for model calls) as a second pass: the person-name masker replaces any
     name the device missed with per-run placeholders `<person:TAG.N>`, `<person:TAG.N.first>`, `<person:TAG.me>`.
     Placeholder-shaped text in the input is first turned into `<name>` so it can never be unmasked into a real name.
- The per-run name map lives in memory for one run only. Real values are needed only to commit; they come from
  connector content (C6) in the runtime right before the gate, never from a model call.
- The user's own name is masked by default (`own_name_to_models = 'mask'`).
- A server-side leak scanner (`packages/masking`) runs on every upload and every model request. It uses the same rules
  as the device, so it is a **transport check**, not an independent second opinion ([ADR 0035](0035-mac-egress-guard-and-ledger.md)).
  A hit refuses the request and writes an audit event `privacy.leak_blocked`.
- Keyframes (images) never reach a model unless the user turned on `keyframes_to_cloud` ([OQ-04](../OPEN_QUESTIONS.md#oq-04-keyframes-to-the-cloud)).
  Images are masked on the Mac (masked OCR lines and secure fields blacked out).

## Consequences
- Drafts written by models contain placeholders or pseudonyms. The runtime fills real values from connector content
  for the approval card and the commit. A draft that still holds a placeholder or `<name>` is never committed
  automatically.
- The approval hash is computed on the real values, so what the user approves is what is sent.
- Real names appear to the user only on his Mac (device-side reveal, [ADR 0028](0028-stable-keyed-pseudonyms.md)) or
  in approval cards built from his own connector content.

## Alternatives considered
- Destructive masking of every name and path on the device (the previous version). Rejected: it removes the join keys
  the brain needs (review-c P0-4).
- Model-based PII detection as the only pass: non-deterministic, and itself needs to see the text. An on-device model
  pass on top of the rules is evaluated in M3 ([ADR 0035](0035-mac-egress-guard-and-ledger.md)).

## Sources
Old ADR 0007, 0010, 0012; old `brain/src/privacy/names.ts`, `engine/Sources/OffloadCore/Detectors/*`; PR #42 A§6.

## Revisions
- 2026-11-14: people, emails, phones and URL paths become stable keyed pseudonyms instead of being destroyed
  (review-c P0-4); server scan described honestly as a transport check (review-c P1(7)); real values for commits come
  from connector content.
- 2026-11-14 (decision pass D): masked text upload confirmed by the owner (OQ-28). No change to the masking rules.
