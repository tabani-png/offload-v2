---
id: m1-04-login-devices
title: Login with one OIDC provider or a magic link, personal tenant on first login, web sessions, device enrollment (authorize + loopback PKCE) and device tokens for audiences device and member
milestone: M1
status: in_progress
depends_on: [m1-02-contracts-ingest, m1-03-tenancy-rls]
parallel_safe: false
human_gated: false
model_tier: sonnet
size: L
parallel_group: M1-D
owns: [services/api/**, docs/API.md]
verify: bash slices/m1-04-login-devices/verify.sh
min_tests: 22
paths_in_scope: [services/api/**, packages/contracts/src/auth/**, packages/contracts/src/index.ts, packages/contracts/schemas/**, packages/db/src/**, packages/testkit/**, slices/m1-04-login-devices/**, docs/API.md, package.json, bun.lock]
paths_out_of_scope: [ee/**, apps/**, services/brain/**, services/builder/**, services/runtime/**, services/broker/**, packages/db/migrations/**, docs/adr/**]
red_tests: [SESSION, ENROLL, TOKEN, AUDIT]
---

# m1-04-login-devices

## Summary
Lets Muhammad log in to his tenant of one and enroll his Mac ([M1](../../docs/ROADMAP.md#m1-foundations)). Implements
[ADR 0014](../../docs/adr/0014-identity.md) and the auth and device routes in
[API.md section 2](../../docs/API.md#2-public-rest). One OIDC provider (Google, against the operator item O5 client in
his Workspace) or an email magic link for self-host. No WorkOS in M1. The Mac UI does not use cookies: it uses device
tokens with audience `member`. Queries live in `packages/db/src/` (no new migrations; every table comes from m1-03).

## Contract
- Delete `services/api/tests/smoke.test.ts` (the TODO marker is replaced).
- Dependencies (exact pins in `services/api/package.json`): `hono`, `jose` (JWT, JWK, ES256 verify).
- Config names: `OFFLOAD_OIDC_ISSUER`, `OFFLOAD_OIDC_CLIENT_ID`, `OFFLOAD_OIDC_CLIENT_SECRET_REF`,
  `OFFLOAD_PUBLIC_BASE_URL`, `OFFLOAD_DEVICE_TOKEN_SIGNING_KEY_REF` (ES256 P-256 private key reference). In tests the
  OIDC issuer and the signing key come from `packages/testkit` (fake issuer with JWKS).
- **Login**: `GET /auth/login?return_to=` (`return_to` must be a same-origin path starting with `/`, else 400
  `invalid_request`), `GET /auth/callback`, `POST /auth/logout`. `/auth/*` sits outside the `/v1` base by design.
  Magic link (self-host): `POST /auth/magic-link { email }` → 204; `GET /auth/magic-link/callback?token=` (token 32
  random bytes, sha256 stored, single use, 15 min). Identity lookup uses `auth_resolve_identity`; unknown subject →
  `createPersonalTenant`.
- **Web session**: cookie `__Host-offload_session` (httpOnly, Secure, SameSite=Lax, Path=/), 12 h absolute, idle 30 min
  for `owner`/`admin` and 8 h otherwise (web only). `GET /v1/me` returns `{ member, tenant, workspaces[], tenant_role,
  features[], csrf_token }`; `csrf_token` is raw, issued once per session (`sessions.csrf_sha256` stored); mutations
  need `X-CSRF-Token`. Session lookup via `auth_resolve_session`.
- **Signatures** (one rule everywhere): ECDSA P-256 / SHA-256, signature = 64-byte raw `r‖s` (JOSE / P1363, Swift
  `rawRepresentation`), base64url without padding. Signed bytes = the exact request body, and the body must equal
  `jcs(JSON.parse(body))` else 400 `invalid_request`. For `POST /v1/devices/token` the signed bytes are the UTF-8 of
  `nonce` as returned. Helper `verifyDeviceSignature(publicJwk, bytes, sig)` exported from `services/api/src/auth/`
  and reused for Mac approvals (`Offload-Signature: keyid=<device_id>, sig=<base64url>`).
- **Enrollment**:
  - `GET /v1/devices/authorize?code_challenge=&code_challenge_method=S256&redirect_uri=&state=` (session required).
    400 `invalid_request` unless `redirect_uri` is `http://127.0.0.1:<port>/callback` with port 1024..65535. Stores
    `device_enrollment_codes` (code 32 random bytes, sha256 stored, 10 min, single use) and 302s to the redirect with
    `code` and `state`.
  - `POST /v1/devices/enroll { code, code_verifier, redirect_uri, public_jwk, name, key_storage: "secure_enclave" |
    "keychain" }` → `{ device_id }` (uuid). `redirect_uri` must equal the stored one; the verifier must match S256;
    the JWK must be EC P-256 with no private part. Code lookup via `auth_resolve_enrollment_code`.
- **Device tokens**: `POST /v1/devices/challenge { device_id, audience: "device" | "member" }` → `{ nonce, expires_at }`
  (nonce 32 bytes base64url, 2 min, stored in `device_nonces` with its audience); `POST /v1/devices/token { device_id,
  nonce, signature }` → `{ token, expires_at }`. ES256 JWT, 15 minutes, `aud` = the nonce's audience, claims `tenant_id`, `member_id`, `device_id`. A used
  nonce → 409 `nonce_used`; an expired nonce → 401 `token_expired`; a revoked device → 401 `unauthenticated`.
  Audience `member` authenticates REST calls from the Mac UI as that member (no cookie, no idle timeout).
- `GET /v1/devices`, `DELETE /v1/devices/{id}` (revokes; existing tokens fail on next use).
- Audit rows through `appendAudit`: `member.logged_in`, `device.enrolled`, `device.revoked`.

## Red tests
Folder: `services/api/tests/m1-04-login-devices/`.

| Tag | Test name | Asserts |
|---|---|---|
| SESSION | SESSION: first login creates a personal tenant with the member as owner | |
| SESSION | SESSION: second login reuses the tenant | |
| SESSION | SESSION: cookie is __Host- prefixed, httpOnly, Secure, SameSite=Lax | |
| SESSION | SESSION: a mutation without X-CSRF-Token is 403 | `forbidden` |
| SESSION | SESSION: GET /v1/me returns the csrf token once per session | second call has none |
| SESSION | SESSION: an owner idle for 31 minutes on the web is 401 token_expired | fake clock |
| SESSION | SESSION: return_to that is not a same-origin path is 400 | `https://evil.example/` |
| SESSION | SESSION: a magic link works once and expires after 15 minutes | |
| ENROLL | ENROLL: authorize with a loopback redirect returns a code and state | 302 |
| ENROLL | ENROLL: a non-loopback redirect_uri is 400 | `http://evil.example/callback` |
| ENROLL | ENROLL: PKCE S256 with loopback redirect returns a device id | uuid |
| ENROLL | ENROLL: a wrong code_verifier is 400 | |
| ENROLL | ENROLL: a redirect_uri different from the authorized one is 400 | |
| ENROLL | ENROLL: a public JWK that is not P-256 is 400 | |
| ENROLL | ENROLL: an enrollment code works once and expires after 10 minutes | |
| TOKEN | TOKEN: signed nonce returns a 15-minute ES256 token | `aud`, `exp`, claims |
| TOKEN | TOKEN: a reused nonce is 409 nonce_used | |
| TOKEN | TOKEN: a revoked device cannot get a token | 401 `unauthenticated` |
| TOKEN | TOKEN: a member-audience token authenticates GET /v1/me without a cookie | a device-audience token is 401 there |
| TOKEN | TOKEN: a DER-encoded signature is rejected and raw r‖s is accepted | fixture produced by Swift `rawRepresentation` |
| AUDIT | AUDIT: device.enrolled is written in the same transaction | `onBeforeCommit` throws; no device, no audit row |
| AUDIT | AUDIT: no token or secret value appears in audit details | |

## Out of scope
SAML, SCIM, WorkOS (M8/M9), team invites (M8), ingest routes (m3-01), pseudonym key wrap routes (m3-01).

## Verify
`bash slices/m1-04-login-devices/verify.sh` (needs `DATABASE_URL`).

## Scope changes
None.
