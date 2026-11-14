# 0005. Masked text only reaches models

Status: accepted · Date: 2026-11-14 · Carries over old ADR 0007, 0010

## Context
Model providers are third parties. Screen text holds names, emails, secrets and numbers.

## Decision
- Masking happens twice:
  1. **On the Mac** before anything is stored or uploaded: secrets, card numbers, CVV/expiry, SSN/SIN, bank routing and
     account numbers, IBAN, CUSIP/ISIN, OTPs, API keys, email addresses, phone numbers, URL paths and query strings,
     and person names. Excluded windows produce no text at all.
  2. **In the model router** (the single egress for model calls) as a second pass: the person-name masker with
     per-run placeholders `<person:TAG.N>`, `<person:TAG.N.first>`, `<person:TAG.me>`. Placeholder-shaped text in the
     input is first turned into `<name>` so it can never be unmasked into a real name.
- The name map lives in memory for one run only. Unmasking happens only where the real value is needed to commit
  (in the runtime, right before the gate), never in a model call.
- The user's own name is masked by default (`own_name_to_models = 'mask'`).
- A server-side leak scanner (`packages/masking`) runs on every upload and every model request. A hit refuses the
  request and writes an audit event `privacy.leak_blocked`.
- Keyframes (images) never reach a model unless the user turned on `keyframes_to_cloud` ([OQ-04](../OPEN_QUESTIONS.md#oq-04-keyframes-to-the-cloud)).
  Images are masked on the Mac (masked OCR lines and secure fields blacked out).

## Consequences
- Drafts written by models contain placeholders. The runtime restores names for the approval card and for the commit.
  A draft that still holds a placeholder or `<name>` is never committed automatically.
- The approval hash is computed on the real (unmasked) text, so what the user approves is what is sent.

## Alternatives considered
- Model-based PII detection: non-deterministic, and itself needs to see the text.

## Sources
Old ADR 0007, 0010, 0012; old `brain/src/privacy/names.ts`, `engine/Sources/OffloadCore/Detectors/*`.
