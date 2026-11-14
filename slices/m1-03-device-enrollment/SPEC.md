---
id: m1-03-device-enrollment
title: OIDC login with personal tenant on first login, sessions, device enrollment (loopback PKCE) and 15-minute device tokens
milestone: M1
status: ready
depends_on: [m1-01-contracts-ingest, m1-02-tenancy-rls]
parallel_safe: false
human_gated: false
verify: bash slices/m1-03-device-enrollment/verify.sh
min_tests: 14
paths_in_scope: [services/api/**, packages/contracts/src/auth/**, packages/testkit/**, slices/m1-03-device-enrollment/**, docs/API.md, package.json, bun.lock]
paths_out_of_scope: [ee/**, apps/**, services/brain/**, services/builder/**, services/runtime/**, docs/adr/**]
red_tests: [ENROLL, TOKEN, SESSION, AUDIT]
---

# m1-03-device-enrollment

## Summary
Lets Muhammad log in to his tenant of one and enroll his Mac. Implements [ADR 0014](../../docs/adr/0014-identity.md)
and the auth and device routes in [API.md section 2](../../docs/API.md#2-public-rest). Adds Hono to `services/api`.
WorkOS is configured only as an OIDC issuer; no WorkOS SDK in core.

## Contract
- `GET /auth/login`, `GET /auth/callback`, `POST /auth/logout`, `GET /v1/me`.
- Session cookie `__Host-offload_session`; 12 h absolute; idle 30 min for `owner`/`admin`; CSRF header on mutations.
- `POST /v1/devices/enroll` (PKCE S256; redirect must be `http://127.0.0.1:<port>/callback`), `POST /v1/devices/challenge`,
  `POST /v1/devices/token` (ES256 JWT, 15 min, `aud = device`, claims `tenant_id`, `member_id`, `device_id`),
  `GET /v1/devices`, `DELETE /v1/devices/{id}`.
- Audit rows (table from m1-02, simple insert; chain hashing in M5): `member.logged_in`, `device.enrolled`, `device.revoked`.
- The OIDC provider is faked in tests (`packages/testkit` fake issuer with JWKS).

## Red tests
Folder: `services/api/tests/m1-03-device-enrollment/`.

| Tag | Test name | Asserts |
|---|---|---|
| SESSION | SESSION: first login creates a personal tenant with the member as owner | |
| SESSION | SESSION: second login reuses the tenant | |
| SESSION | SESSION: cookie is __Host- prefixed, httpOnly, Secure, SameSite=Lax | |
| SESSION | SESSION: a mutation without X-CSRF-Token is 403 | |
| SESSION | SESSION: an owner idle for 31 minutes is 401 token_expired | fake clock |
| ENROLL | ENROLL: PKCE S256 with loopback redirect returns a device id | |
| ENROLL | ENROLL: a non-loopback redirect_uri is 400 | `http://evil.example/callback` |
| ENROLL | ENROLL: a wrong code_verifier is 400 | |
| ENROLL | ENROLL: a public JWK that is not P-256 is 400 | |
| TOKEN | TOKEN: signed nonce returns a 15-minute ES256 token | `aud`, `exp`, claims |
| TOKEN | TOKEN: a reused nonce is 409 | |
| TOKEN | TOKEN: a revoked device cannot get a token | 401 |
| AUDIT | AUDIT: device.enrolled is written in the same transaction | rollback leaves no row |
| AUDIT | AUDIT: no token or secret value appears in audit details | |

## Out of scope
SAML, SCIM (EE), team invites, ingest routes.

## Verify
`bash slices/m1-03-device-enrollment/verify.sh`.

## Scope changes
None.
