# 0015. Open-core layout (`ee/`) and runtime license gating

Status: accepted; license texts pending [OQ-11](../OPEN_QUESTIONS.md#oq-11-license-for-the-core-and-for-ee) · Date: 2026-11-14

## Context
Offload will be open core: a free core, Pro (hosted teams) and Enterprise (governance, SSO/SCIM, deployment options).
The boundary must exist in the code from day one.

## Decision
- **Layout (Langfuse style)**: all Enterprise code lives under top-level `ee/` (`ee/packages/*`, package scope
  `@offload-ee/*`). Everything else is core.
- **Import rule**: core (`apps/`, `packages/`, `services/`) never imports `ee/`. `ee/` may import core.
  `scripts/check-license-boundary.sh` enforces it in CI (static imports, dynamic `import()`, `require()`, manifests,
  tsconfig paths) and has its own tests.
- **Extension points**: core defines ports and a plugin registry (`registerPlugin({ name, feature, provides })`).
  The Enterprise build has its own composition root, `@offload-ee/server-ee`, which imports the core services and
  registers EE plugins. The core entry never loads EE code.
- **Runtime gating**: `packages/license` verifies an Ed25519-signed license key (`OFFLOAD_EE_LICENSE_KEY`) offline:
  payload `{ licensee, plan, features[], seats, expires_at, issued_at, key_id }`. EE plugins check the entitlement at
  startup and on each use. Invalid or expired keys disable EE features and keep core running. The license public keys
  are compiled into `packages/license`.
- **Licenses (recommended default, owner decision OQ-11)**: Apache-2.0 for core (patent grant), a commercial
  Enterprise license for `ee/`, source-visible, production use needs a key. Until decided, `LICENSE` and `ee/LICENSE`
  are placeholders that grant nothing.
- **What is EE** is listed in [OPEN_CORE.md](../OPEN_CORE.md#2-feature-split). Safety features (gates, masking,
  basic audit log, kill switches, forget/export) are core: trust is not an upgrade.
- Pro is a hosting plan, not a code tier: it runs core plus a few EE features enabled by Offload Cloud's own key.

## Consequences
- One codebase for OSS, self-hosted Enterprise and Offload Cloud.
- Third-party code ported into either side keeps its notice in `NOTICE`.

## Alternatives considered
- n8n-style `.ee.` file suffixes spread through the tree: harder to check mechanically.
- Separate private repo for EE: drift and double CI.
- Fair-code license (Sustainable Use) for core: not OSI open source; owner asked for open source core.

## Sources
Langfuse, n8n, Temporal and Composio licensing (summarized in [OPEN_CORE.md](../OPEN_CORE.md#4-how-others-split)).
