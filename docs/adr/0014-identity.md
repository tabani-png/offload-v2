# 0014. Identity: OIDC in core, SAML/SCIM in EE, device keys

Status: accepted · Date: 2026-11-14 · Carries over old ADR 0102, 0111

## Context
Self-hosters need login without a vendor. Offload Cloud wants hosted login. Enterprise needs SSO and SCIM. Macs need
device credentials without long-lived bearer tokens.

## Decision
- **Core**: OpenID Connect login against any OIDC provider (`OFFLOAD_OIDC_ISSUER`, client id, secret), plus email
  magic link for self-host. Sessions are server-side rows; cookie `__Host-offload_session` (httpOnly, Secure,
  SameSite=Lax), 12 hours absolute, idle timeout 30 minutes for `owner`/`admin`, 8 hours otherwise; CSRF header token
  on mutations.
- **Offload Cloud** uses **WorkOS AuthKit** as its OIDC provider (Google, Microsoft, magic link) through the same core
  OIDC path. Choice of vendor is [OQ-06](../OPEN_QUESTIONS.md#oq-06-identity-provider-for-offload-cloud).
- **EE**: SAML SSO, enforced SSO per tenant, SCIM 2.0 provisioning and deprovisioning, directory group → workspace
  mapping, custom roles. Implemented in `ee/packages/identity`. On Offload Cloud through WorkOS; on self-host through a
  SAML/SCIM library chosen in M9.
- **Tenant roles**: `owner`, `admin`, `member`, `auditor`; non-human `service`. `owner` is never assigned from an IdP.
  At least one owner at all times (removing the last returns 409). Workspace roles: `lead`, `member`.
- **Device enrollment**: loopback PKCE (S256). The Mac opens the browser, the user logs in, the callback hits
  `http://127.0.0.1:<port>/callback`, the Mac posts `POST /v1/devices/enroll` with the code verifier and its P-256
  public key (JWK). The private key stays in the Keychain, non-exportable.
- **Device token**: `POST /v1/devices/token` with a signature over a server nonce returns an ES256 JWT, 15 minutes,
  audience `device`. No long-lived bearer on the Mac.
- Deprovisioning (SCIM or manual) revokes sessions and device tokens at once and pauses the member's routines.

## Consequences
- The core never depends on WorkOS. Cloud does, through configuration.

## Alternatives considered
- WorkOS in core: vendor lock for self-hosters.
- Long-lived device API keys: rejected (old ADR 0102).

## Sources
Old ADR 0102, 0111; old `control/src/auth/*`.
