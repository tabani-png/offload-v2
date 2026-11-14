# 0015. Open-core layout (`ee/`) and runtime license gating

Status: accepted, revised 2026-11-14; licenses decided 2026-11-14 ([OQ-11](../OPEN_QUESTIONS.md#oq-11-license-for-the-core-and-for-ee), [ADR 0038](0038-license-mit-core-commercial-ee.md)), plan split decided 2026-11-14 ([OQ-13](../OPEN_QUESTIONS.md#oq-13-plan-contents-and-prices)), prices open · Date: 2026-11-14

## Context
Offload will be open core: a free core, Pro (teams) and Enterprise (governance, SSO/SCIM, deployment options). The
boundary must exist in the code from day one. With a permissive core, anyone can host the same product, so what sits
outside the core must be something a hosted clone cannot just switch on ([design review C (2026-11-14)](../SOURCES.md#design-review-c), P1(6)).

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
- **Runtime gating**: `packages/license` verifies Ed25519-signed license keys (`OFFLOAD_EE_LICENSE_KEY`, one key or
  one per plan) offline: payload `{ licensee, plan, features[], seats, expires_at, issued_at, key_id }`. A tenant's
  entitlements are the features of the key whose `plan` equals `tenants.plan`, identically on Offload Cloud (its own
  key per plan) and self-host (the customer's key) ([ADR 0037](0037-hosting-cloud-and-self-host-parity.md)). EE plugins check the entitlement at
  startup and on each use. Invalid or expired keys disable EE features and keep core running. The license public keys
  are compiled into `packages/license`. The check is a legal boundary more than a technical one, as with Langfuse.
- **Plan split, decided by the owner on 2026-11-14** ("One person free, teams pay.", OQ-13): **single-player core
  free, multiplayer paid through Pro**. Core is everything one person needs, self-host included. Team tenants
  (`kind = 'team'`: invites, workspaces, shared fixes, team review) live in `ee/packages/teams` and are enabled by a
  key with the `teams` feature (Offload Cloud's Pro key, or a self-hoster's key). Enterprise adds SSO/SCIM, approval
  chains, SIEM/audit export, BYOC and support; custom policies and the external audit anchor sink are Enterprise by
  default. One gate (team tenant creation) is easy to enforce. Prices are not decided.
- **Pro runs one EE feature**: `teams`.
- **Licenses (decided 2026-11-14, OQ-11, [ADR 0038](0038-license-mit-core-commercial-ee.md))**: MIT for core; the
  Offload Enterprise License for `ee/` (proprietary, source-available, dev and test use free, production use needs a
  key and a subscription; draft pending legal review).
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
- Fair-code license (Sustainable Use) for core: not OSI open source; owner asked for open source core. Closed by
  the OQ-13 answer.

## Sources
Langfuse, n8n, Temporal and Composio licensing (summarized in [OPEN_CORE.md](../OPEN_CORE.md#4-how-others-split)).

## Revisions
- 2026-11-14 (license decision): OQ-11 decided, MIT core and the Offload Enterprise License for `ee/`
  ([ADR 0038](0038-license-mit-core-commercial-ee.md)); the Apache-2.0 default is replaced.
- 2026-11-14 (decision pass D): plan split decided by the owner (OQ-13); hosting-only Pro and fair-code core
  alternatives closed; license gating per tenant plan, identical in Cloud and self-host (ADR 0037).
- 2026-11-14: recommended default plan split "single-player core, multiplayer paid", all split values pending OQ-13
  ([design review C (2026-11-14)](../SOURCES.md#design-review-c), P1(6), [design review B (2026-11-14)](../SOURCES.md#design-review-b), 9/10); Pro "none by default" aligned with OPEN_CORE ([design review A (2026-11-14)](../SOURCES.md#design-review-a), #107); EE route mounting and
  403 vs 404 ([design review A (2026-11-14)](../SOURCES.md#design-review-a), #57).
