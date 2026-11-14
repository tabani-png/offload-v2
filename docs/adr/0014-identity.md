# 0014. Identity: one OIDC provider in core, SAML/SCIM in EE, device keys

Status: accepted, revised 2026-11-14 · Date: 2026-11-14 · Carries over old ADR 0102, 0111

## Context
Self-hosters need login without a vendor. The tenant of one needs one login, not an identity platform. Pro teams want
hosted login; Enterprise needs SSO and SCIM. Macs need credentials without long-lived bearer tokens, and the owner must
not be logged out of his own Mac app every half hour (review-c P1(5)).

## Decision
- **Core web login**: OpenID Connect against one configured provider (`OFFLOAD_OIDC_ISSUER`, client id, secret), or
  email magic link for self-host. For M1 the tenant of one uses Google as the OIDC provider through his own
  Workspace OAuth client (operator item O5). `return_to` accepts same-origin paths only.
- **Web sessions**: server-side rows; cookie `__Host-offload_session` (httpOnly, Secure, SameSite=Lax), 12 hours
  absolute, idle timeout 30 minutes for `owner`/`admin`, 8 hours otherwise; CSRF token returned by `GET /v1/me` once per
  session (`sessions.csrf_sha256` stored), sent as `X-CSRF-Token` on mutations. These timeouts apply to the web app only.
- **WorkOS AuthKit** is used from M8 for Pro on Offload Cloud, through the same core OIDC path ([OQ-06](../OPEN_QUESTIONS.md#oq-06-identity-provider-for-offload-cloud)).
  The core never depends on it.
- **EE**: SAML SSO, enforced SSO per tenant, SCIM 2.0 provisioning and deprovisioning, directory group → workspace
  mapping, custom roles. `ee/packages/identity`, M9.
- **Tenant roles**: `owner`, `admin`, `member`, `auditor`; non-human `service`. `owner` is never assigned from an IdP.
  At least one owner at all times (`setMemberRole`/`setMemberState` raise `last_owner`, HTTP 409). Workspace roles:
  `lead`, `member`.
- **Device key**: P-256, generated in the **Secure Enclave** where available (non-exportable there), else a Keychain
  item marked this-device-only. The public key is registered as a JWK at enrollment.
- **Device enrollment** (loopback PKCE S256): the Mac opens `GET /v1/devices/authorize?code_challenge=…&code_challenge_method=S256&redirect_uri=http://127.0.0.1:<port>/callback&state=…`
  in the browser; with a session, the server stores a 10-minute single-use code in `device_enrollment_codes` and
  redirects to the loopback with `code` and `state`; a non-loopback `redirect_uri` is 400. The Mac posts
  `POST /v1/devices/enroll { code, code_verifier, redirect_uri, public_jwk, name, key_storage }`; `redirect_uri` must equal the stored
  value.
- **Device tokens**: `POST /v1/devices/challenge { device_id, audience }` returns a 2-minute nonce bound to that
  audience; `POST /v1/devices/token { device_id, nonce, signature }` returns an ES256 JWT, 15 minutes, with that
  audience. Audience `device` is for ingest and device commands;
  audience `member` lets the **Mac UI call the REST API as that member** with no cookie session. A reused nonce is
  `409 nonce_used`.
- **Signatures**: ECDSA P-256 with SHA-256, encoded as the 64-byte raw `r‖s` (JOSE/P1363, Swift
  `ECDSASignature.rawRepresentation`), base64url without padding. For the token endpoint the signed bytes are the UTF-8
  nonce. For signed bodies the signed bytes are the exact request body, which must equal `jcs(JSON.parse(body))`.
- **Approvals from the Mac** carry `Offload-Signature: keyid=<device_id>, sig=<…>` over the JCS body; the server verifies
  it and stores `approvals.approver_device_id`.
- Deprovisioning (SCIM or manual) revokes sessions and device tokens at once and pauses the member's routines.

## Consequences
- M1 needs one OIDC client and no identity vendor.
- The Mac app never holds a cookie session and never times out on its owner; a stolen Mac is handled by device revoke.

## Alternatives considered
- WorkOS in M1 (the previous version): a vendor the tenant of one does not need (review-c P1(5)).
- Cookie sessions for the Mac UI: logs the owner out every 30 minutes.
- Long-lived device API keys: rejected (old ADR 0102).

## Sources
Old ADR 0102, 0111; old `control/src/auth/*`; PR #42 A§13.1 (device-key enrollment).

## Revisions
- 2026-11-14: one OIDC provider or magic link in M1, WorkOS from M8; Mac UI via device token audience `member` and
  device-signed approvals (review-c P1(5)); Secure Enclave wording (review-c P2); authorize step and code table
  (review-a #3); signature encoding (review-a #4); CSRF delivery (review-a #37); `nonce_used` (review-a #36);
  `return_to` same-origin (review-a #113); last-owner helper names (review-a #32).
- 2026-11-14 (final pass): challenge carries the audience and the nonce lives 2 minutes; enroll body includes `key_storage` (final-pass audit, matching API.md and m1-04).
