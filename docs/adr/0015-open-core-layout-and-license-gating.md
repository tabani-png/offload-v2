# 0015. Open-core layout (`ee/`) and runtime license gating

Status: accepted, revised 2026-11-14; license texts pending [OQ-11](../OPEN_QUESTIONS.md#oq-11-license-for-the-core-and-for-ee), plan split pending [OQ-13](../OPEN_QUESTIONS.md#oq-13-plan-contents-and-prices) · Date: 2026-11-14

## Context
Offload will be open core: a free core, Pro (teams) and Enterprise (governance, SSO/SCIM, deployment options). The
boundary must exist in the code from day one. With a permissive core, anyone can host the same product, so what sits
outside the core must be something a hosted clone cannot just switch on (review-c P1(6)).

## Decision
- **Layout (Langfuse style)**: all Enterprise code lives under top-level `ee/` (`ee/packages/*`, package scope
  `@offload-ee/*`). Everything else is core.
- **Import rule**: core (`apps/`, `packages/`, `services/`) never imports `ee/`. `ee/` may import core.
  `scripts/check-license-boundary.sh` enforces it in CI (static imports, dynamic `import()`, `require()`, manifests,
  tsconfig paths) and has its own tests.
- **Extension points**: core defines ports and a plugin registry (`registerPlugin({ name, feature, provides })`).
  The Enterprise build has its own composition root, `@offload-ee/server-ee`, which imports the core services and
  registers EE plugins. The core entry never loads EE code.
- **Routes**: the EE composition root always mounts EE routes and returns `403 feature_not_licensed` when the key does
  not entitle the feature. The core root does not mount them, so they are `404` there.
- **Runtime gating**: `packages/license` verifies an Ed25519-signed license key (`OFFLOAD_EE_LICENSE_KEY`) offline:
  payload `{ licensee, plan, features[], seats, expires_at, issued_at, key_id }`. EE plugins check the entitlement at
  startup and on each use. Invalid or expired keys disable EE features and keep core running. The license public keys
  are compiled into `packages/license`. The check is a legal boundary more than a technical one, as with Langfuse.
- **Plan split, default pending OQ-13**: the recommended default is **single-player is core, multiplayer is paid**.
  Core is everything one person needs, self-host included. Team tenants (`kind = 'team'`: invites, workspaces, shared
  fixes, team review) live in `ee/packages/teams` and are enabled by Offload Cloud's key for Pro. Enterprise adds
  SSO/SCIM, approval chains, custom policies, SIEM, an external audit anchor sink, BYOC and support. One gate (team
  tenant creation) is easy to enforce. Alternatives kept open in OQ-13: Pro as a hosting plan with no EE features
  (the previous default), or a fair-code core.
- **Pro runs no EE features by default other than what OQ-13 decides**; under the recommended default that is the
  `teams` feature only.
- **Licenses (recommended default, owner decision OQ-11)**: Apache-2.0 for core (patent grant), a commercial
  Enterprise license for `ee/`, source-visible, production use needs a key. Until decided, `LICENSE` and `ee/LICENSE`
  are placeholders that grant nothing.
- **What is EE** is listed in [OPEN_CORE.md](../OPEN_CORE.md#2-feature-split). Safety features (gates, masking,
  basic audit log, kill switches, forget/export) are core: trust is not an upgrade.

## Consequences
- One codebase for OSS, self-hosted Enterprise and Offload Cloud.
- Third-party code ported into either side keeps its notice in `NOTICE`.
- Some EE value is thin over core (audit export is paging a core endpoint); the EE value is SSO/SCIM, approval chains,
  SIEM, BYOC, teams and support.

## Alternatives considered
- n8n-style `.ee.` file suffixes spread through the tree: harder to check mechanically.
- Separate private repo for EE: drift and double CI.
- Fair-code license (Sustainable Use) for core: not OSI open source; owner asked for open source core. Kept as an OQ-13
  alternative.

## Sources
Langfuse, n8n, Temporal and Composio licensing (summarized in [OPEN_CORE.md](../OPEN_CORE.md#4-how-others-split)).

## Revisions
- 2026-11-14: recommended default plan split "single-player core, multiplayer paid", all split values pending OQ-13
  (review-c P1(6), review-b 9/10); Pro "none by default" aligned with OPEN_CORE (review-a #107); EE route mounting and
  403 vs 404 (review-a #57).
