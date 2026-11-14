# 0028. Stable keyed pseudonyms and device-side reveal

Status: accepted · Date: 2026-11-14

## Context
On-device masking replaced emails, phones, names and URL paths with per-run placeholders or removed them. That
destroyed the join keys the cloud brain needs: every Google Sheet became `docs.google.com`, names could not be matched
across days, and "the same 4 docs" or "which customer" could not be computed ([design review C (2026-11-14)](../SOURCES.md#design-review-c), P0-4). PR #42 kept names and
paths in the local store for this reason (A§6.1). The ingest contract freezes the choice, so it is made now.

## Decision
- The Mac emits **stable keyed pseudonyms**: `HMAC-SHA256(tenant pseudonym key, normalised value)`, first 16 hex,
  shape `<KIND:h_0123456789abcdef>`. Kinds: `person`, `email`, `phone`, `doc` (URL path or document id).
- **Normalisation**: Unicode NFKC and trim for all; lowercase for `email` and `doc`; `phone` as E.164 digits; `person`
  as lowercased "first last".
- **URLs**: host kept; path becomes `<doc:h_…>`; query string and fragment dropped.
- **Structured secrets stay destructively masked** (cards, CVV/expiry, bank numbers, IBAN, government ids, OTPs, API
  keys): no pseudonym, no way back ([ADR 0005](0005-masked-text-only-reaches-models.md)).
- **Key**: one per tenant, 32 random bytes, generated on the first enrolled Mac and held in its Keychain. It is never
  stored server-side in the clear.
  - **Second Mac**: an already enrolled Mac wraps the key to the new device's P-256 public key (ECDH P-256 + HKDF-SHA256
    + AES-256-GCM) and uploads the wrapped blob (`pseudonym_key_wraps`); the new Mac unwraps it.
  - **No other Mac online**: the owner types the recovery code shown once at first enrollment; the key is wrapped by a
    key derived from it with scrypt, and that wrapped copy is what the server stores.
- **Device-side reveal**: the Mac keeps a local reveal map (C0, 7 days) from pseudonym to value. The UI shows real
  names only on the device; after 7 days it says "seen before last week".
- **Pseudonym match**: when the fix designer must ask "is this the sheet?", the server sends candidate values from a
  connector (C6) to the Mac UI; the Mac hashes them with the key and posts matches with `POST /v1/pseudonyms/matches`.
  The server learns which candidate equals which pseudonym, never the key.
- The model router still masks any leftover names with per-run placeholders `<person:TAG.N>`.

## Consequences
- Equality survives upload; values do not. Entity resolution, task induction and briefs work on pseudonyms.
- Losing every Mac and the recovery code means old pseudonyms can no longer be matched to new ones; the user model
  keeps working on new data.
- In a team tenant, members share the tenant key; the member wall in RLS still separates their data.
- The ingest contract (slice `m1-02-contracts-ingest`) defines the pseudonym grammar.

## Alternatives considered
- Per-run placeholders on the device (the previous version): no cross-day equality.
- Salted hashes computed on the server: the server would see the values first.
- A key per member: makes shared customers in a team unmatched; the member wall already separates data.

## Sources
[Design review C (2026-11-14)](../SOURCES.md#design-review-c), P0-4; PR #42 A§6.1, A§6.2; old `brain/src/privacy/names.ts`.
